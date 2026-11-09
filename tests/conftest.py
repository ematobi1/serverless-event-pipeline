import json
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

import handler  # noqa: E402

REGION = "us-east-1"
TABLE_NAME = "orders-test"
QUEUE_NAME = "orders-test"
STATE_MACHINE_NAME = "orders-test"


@pytest.fixture(autouse=True)
def aws_environment(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.delenv("AWS_PROFILE", raising=False)
    handler.aws_client.cache_clear()
    with mock_aws():
        yield
    handler.aws_client.cache_clear()


@pytest.fixture
def resources(monkeypatch):
    dynamodb = boto3.client("dynamodb", region_name=REGION)
    dynamodb.create_table(
        TableName=TABLE_NAME,
        KeySchema=[{"AttributeName": "orderId", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "orderId", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    sqs = boto3.client("sqs", region_name=REGION)
    queue_url = sqs.create_queue(QueueName=QUEUE_NAME)["QueueUrl"]

    iam = boto3.client("iam", region_name=REGION)
    role_arn = iam.create_role(
        RoleName="sfn-test",
        AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": []}),
    )["Role"]["Arn"]
    stepfunctions = boto3.client("stepfunctions", region_name=REGION)
    state_machine_arn = stepfunctions.create_state_machine(
        name=STATE_MACHINE_NAME,
        definition=json.dumps({"StartAt": "Done", "States": {"Done": {"Type": "Succeed"}}}),
        roleArn=role_arn,
    )["stateMachineArn"]

    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("QUEUE_URL", queue_url)
    monkeypatch.setenv("STATE_MACHINE_ARN", state_machine_arn)

    return {
        "dynamodb": dynamodb,
        "sqs": sqs,
        "stepfunctions": stepfunctions,
        "queue_url": queue_url,
        "state_machine_arn": state_machine_arn,
    }
