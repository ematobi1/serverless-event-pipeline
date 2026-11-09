"""Static checks on the ASL template so a broken state machine fails in CI, not in AWS."""

import json
from pathlib import Path

ASL_PATH = (
    Path(__file__).resolve().parent.parent
    / "terraform"
    / "statemachine"
    / "order_workflow.asl.json"
)


def load_definition():
    rendered = ASL_PATH.read_text().replace("${table_name}", "orders-test")
    return json.loads(rendered)


def test_definition_is_valid_json_with_existing_start_state():
    definition = load_definition()

    assert definition["StartAt"] in definition["States"]


def test_every_transition_targets_an_existing_state():
    states = load_definition()["States"]
    targets = []
    for state in states.values():
        targets.append(state.get("Next"))
        targets.append(state.get("Default"))
        targets.extend(choice["Next"] for choice in state.get("Choices", []))
        targets.extend(catcher["Next"] for catcher in state.get("Catch", []))

    assert {target for target in targets if target} <= set(states)


def test_update_only_touches_existing_orders():
    task = load_definition()["States"]["MarkProcessed"]

    assert task["Resource"] == "arn:aws:states:::dynamodb:updateItem"
    assert task["Parameters"]["TableName"] == "orders-test"
    assert task["Parameters"]["ConditionExpression"] == "attribute_exists(orderId)"
