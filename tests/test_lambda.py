import base64
import json

import pytest

import handler
from conftest import TABLE_NAME


def sqs_record(body, message_id="msg-1"):
    payload = body if isinstance(body, str) else json.dumps(body)
    return {"messageId": message_id, "body": payload, "eventSource": "aws:sqs"}


def api_event(body, base64_encoded=False):
    raw = body if isinstance(body, str) else json.dumps(body)
    if base64_encoded:
        raw = base64.b64encode(raw.encode()).decode()
    return {
        "requestContext": {"http": {"method": "POST", "path": "/orders"}},
        "body": raw,
        "isBase64Encoded": base64_encoded,
    }


def get_order(resources, order_id):
    return (
        resources["dynamodb"]
        .get_item(TableName=TABLE_NAME, Key={"orderId": {"S": order_id}})
        .get("Item")
    )


def executions(resources):
    return resources["stepfunctions"].list_executions(
        stateMachineArn=resources["state_machine_arn"]
    )["executions"]


VALID_ORDER = {"orderId": "order-001", "customerId": "cust-42", "amount": 19.99}


class TestSqsProcessing:
    def test_valid_message_writes_item_and_starts_workflow(self, resources):
        result = handler.lambda_handler({"Records": [sqs_record(VALID_ORDER)]}, None)

        assert result == {"batchItemFailures": []}
        item = get_order(resources, "order-001")
        assert item["customerId"] == {"S": "cust-42"}
        assert item["amount"] == {"N": "19.99"}
        assert item["currency"] == {"S": "USD"}
        assert item["status"] == {"S": "RECEIVED"}
        started = executions(resources)
        assert [execution["name"] for execution in started] == ["order-001"]

    def test_invalid_json_is_reported_as_failure(self, resources):
        result = handler.lambda_handler({"Records": [sqs_record("{not json", "bad")]}, None)

        assert result == {"batchItemFailures": [{"itemIdentifier": "bad"}]}
        assert executions(resources) == []

    @pytest.mark.parametrize(
        "order",
        [
            {"orderId": "o1", "amount": 10},
            {"orderId": "o1", "customerId": "c", "amount": -5},
            {"orderId": "o1", "customerId": "c", "amount": "NaN"},
            {"orderId": "o1", "customerId": "c", "amount": True},
            {"orderId": "has spaces", "customerId": "c", "amount": 1},
            {"orderId": "o1", "customerId": "c", "amount": 1, "currency": "usd"},
            ["not", "an", "object"],
        ],
    )
    def test_invalid_orders_are_reported_as_failures(self, resources, order):
        result = handler.lambda_handler({"Records": [sqs_record(order, "bad")]}, None)

        assert result == {"batchItemFailures": [{"itemIdentifier": "bad"}]}

    def test_mixed_batch_reports_only_failed_records(self, resources):
        records = [
            sqs_record(VALID_ORDER, "good-1"),
            sqs_record({"orderId": "x"}, "bad-1"),
            sqs_record({**VALID_ORDER, "orderId": "order-002"}, "good-2"),
        ]

        result = handler.lambda_handler({"Records": records}, None)

        assert result == {"batchItemFailures": [{"itemIdentifier": "bad-1"}]}
        assert get_order(resources, "order-001") is not None
        assert get_order(resources, "order-002") is not None

    def test_redelivered_message_is_idempotent(self, resources):
        handler.lambda_handler({"Records": [sqs_record(VALID_ORDER, "m1")]}, None)
        first = get_order(resources, "order-001")

        result = handler.lambda_handler(
            {"Records": [sqs_record({**VALID_ORDER, "amount": 999}, "m1-retry")]}, None
        )

        assert result == {"batchItemFailures": []}
        assert get_order(resources, "order-001") == first
        assert len(executions(resources)) == 1

    def test_dynamodb_failure_is_reported(self, resources, monkeypatch):
        monkeypatch.setenv("TABLE_NAME", "missing-table")

        result = handler.lambda_handler({"Records": [sqs_record(VALID_ORDER, "m1")]}, None)

        assert result == {"batchItemFailures": [{"itemIdentifier": "m1"}]}
        assert executions(resources) == []


class TestApiGateway:
    def test_valid_request_enqueues_order(self, resources):
        response = handler.lambda_handler(api_event(VALID_ORDER), None)

        assert response["statusCode"] == 202
        assert json.loads(response["body"]) == {"orderId": "order-001", "status": "ACCEPTED"}
        messages = resources["sqs"].receive_message(QueueUrl=resources["queue_url"])["Messages"]
        assert json.loads(messages[0]["Body"]) == {
            "orderId": "order-001",
            "customerId": "cust-42",
            "amount": "19.99",
            "currency": "USD",
        }

    def test_order_id_is_generated_when_missing(self, resources):
        response = handler.lambda_handler(api_event({"customerId": "cust-42", "amount": 5}), None)

        assert response["statusCode"] == 202
        assert len(json.loads(response["body"])["orderId"]) == 36

    def test_base64_body_is_decoded(self, resources):
        response = handler.lambda_handler(api_event(VALID_ORDER, base64_encoded=True), None)

        assert response["statusCode"] == 202

    def test_malformed_json_returns_400(self, resources):
        response = handler.lambda_handler(api_event("{oops"), None)

        assert response["statusCode"] == 400
        assert json.loads(response["body"])["error"]["code"] == "INVALID_JSON"

    def test_validation_error_returns_422_with_error_shape(self, resources):
        response = handler.lambda_handler(api_event({"orderId": "o1", "amount": 1}), None)

        assert response["statusCode"] == 422
        assert response["headers"]["Content-Type"] == "application/json"
        error = json.loads(response["body"])["error"]
        assert error["code"] == "VALIDATION_FAILED"
        assert "customerId" in error["message"]

    def test_queue_failure_returns_generic_500(self, resources, monkeypatch):
        monkeypatch.setenv("QUEUE_URL", resources["queue_url"] + "-missing")

        response = handler.lambda_handler(api_event(VALID_ORDER), None)

        assert response["statusCode"] == 500
        body = json.loads(response["body"])
        assert body == {
            "error": {"code": "INTERNAL_ERROR", "message": "Order could not be accepted"}
        }


def test_unknown_event_type_raises():
    with pytest.raises(ValueError):
        handler.lambda_handler({"foo": "bar"}, None)
