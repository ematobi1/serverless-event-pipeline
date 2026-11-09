"""Order pipeline Lambda.

One function, two entry points:
  * API Gateway (HTTP API, payload v2): validates an order and enqueues it on SQS.
  * SQS event source mapping: persists each order to DynamoDB and starts a
    Step Functions execution. Failed records are reported individually via
    ``batchItemFailures`` so only they are retried (and land in the DLQ after
    ``maxReceiveCount`` attempts).
"""

import base64
import json
import logging
import os
import re
import uuid
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from functools import cache

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

ORDER_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
CURRENCY_PATTERN = re.compile(r"^[A-Z]{3}$")
MAX_AMOUNT = Decimal("1000000")


class ValidationError(Exception):
    pass


@cache
def aws_client(service_name):
    return boto3.client(service_name)


def validate_order(payload):
    if not isinstance(payload, dict):
        raise ValidationError("order must be a JSON object")

    order_id = payload.get("orderId") or str(uuid.uuid4())
    if not isinstance(order_id, str) or not ORDER_ID_PATTERN.match(order_id):
        raise ValidationError("orderId must be 1-80 characters of [A-Za-z0-9_-]")

    customer_id = payload.get("customerId")
    if not isinstance(customer_id, str) or not 1 <= len(customer_id) <= 128:
        raise ValidationError("customerId must be a string of 1-128 characters")

    raw_amount = payload.get("amount")
    if isinstance(raw_amount, bool) or not isinstance(raw_amount, (int, float, str)):
        raise ValidationError("amount must be a number")
    try:
        amount = Decimal(str(raw_amount))
    except InvalidOperation as err:
        raise ValidationError("amount must be a number") from err
    if not amount.is_finite() or amount <= 0 or amount > MAX_AMOUNT:
        raise ValidationError(f"amount must be greater than 0 and at most {MAX_AMOUNT}")

    currency = payload.get("currency", "USD")
    if not isinstance(currency, str) or not CURRENCY_PATTERN.match(currency):
        raise ValidationError("currency must be a 3-letter ISO 4217 code")

    return {
        "orderId": order_id,
        "customerId": customer_id,
        "amount": str(amount),
        "currency": currency,
    }


def api_response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def api_error(status_code, code, message):
    return api_response(status_code, {"error": {"code": code, "message": message}})


def handle_api_request(event):
    try:
        raw_body = event.get("body") or ""
        if event.get("isBase64Encoded"):
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        order = validate_order(json.loads(raw_body))
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        return api_error(400, "INVALID_JSON", "Request body must be valid JSON")
    except ValidationError as err:
        return api_error(422, "VALIDATION_FAILED", str(err))

    try:
        aws_client("sqs").send_message(
            QueueUrl=os.environ["QUEUE_URL"],
            MessageBody=json.dumps(order),
        )
    except ClientError:
        logger.exception("Failed to enqueue order %s", order["orderId"])
        return api_error(500, "INTERNAL_ERROR", "Order could not be accepted")

    logger.info(json.dumps({"event": "order_enqueued", "orderId": order["orderId"]}))
    return api_response(202, {"orderId": order["orderId"], "status": "ACCEPTED"})


def persist_order(order):
    """Insert the order once. Returns False when it already exists (SQS redelivery)."""
    try:
        aws_client("dynamodb").put_item(
            TableName=os.environ["TABLE_NAME"],
            Item={
                "orderId": {"S": order["orderId"]},
                "customerId": {"S": order["customerId"]},
                "amount": {"N": order["amount"]},
                "currency": {"S": order["currency"]},
                "status": {"S": "RECEIVED"},
                "createdAt": {"S": datetime.now(UTC).isoformat()},
            },
            ConditionExpression="attribute_not_exists(orderId)",
        )
    except ClientError as err:
        if err.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise
    return True


def start_workflow(order_id):
    """Execution name = orderId makes the start idempotent across retries."""
    try:
        aws_client("stepfunctions").start_execution(
            stateMachineArn=os.environ["STATE_MACHINE_ARN"],
            name=order_id,
            input=json.dumps({"orderId": order_id, "source": "lambda"}),
        )
    except ClientError as err:
        if err.response["Error"]["Code"] != "ExecutionAlreadyExists":
            raise


def process_record(record):
    order = validate_order(json.loads(record["body"]))
    inserted = persist_order(order)
    start_workflow(order["orderId"])
    logger.info(
        json.dumps(
            {
                "event": "order_processed",
                "orderId": order["orderId"],
                "messageId": record["messageId"],
                "duplicate": not inserted,
            }
        )
    )


def handle_sqs_batch(records):
    failures = []
    for record in records:
        try:
            process_record(record)
        except (json.JSONDecodeError, ValidationError) as err:
            logger.warning(
                json.dumps(
                    {
                        "event": "order_rejected",
                        "messageId": record["messageId"],
                        "reason": str(err),
                    }
                )
            )
            failures.append({"itemIdentifier": record["messageId"]})
        except ClientError:
            logger.exception("AWS error processing message %s", record["messageId"])
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}


def lambda_handler(event, context):
    if "Records" in event:
        return handle_sqs_batch(event["Records"])
    if "requestContext" in event:
        return handle_api_request(event)
    raise ValueError("Unsupported event type")
