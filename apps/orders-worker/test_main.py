import json
import logging
from unittest.mock import MagicMock

import main


def test_valid_order_is_logged_as_json_and_acked(caplog):
    message = MagicMock(data=json.dumps({"order_id": "1", "item": "book", "quantity": 2}).encode())
    with caplog.at_level(logging.INFO, logger="orders-worker"):
        main.handle_message(message)
    message.ack.assert_called_once()
    record = caplog.records[0]
    assert record.fields["order"]["order_id"] == "1"
    entry = json.loads(main.JsonFormatter().format(record))
    assert entry["severity"] == "INFO" and entry["order"]["item"] == "book"


def test_invalid_message_is_acked_and_logged_as_error(caplog):
    message = MagicMock(data=b"not json", message_id="m1")
    with caplog.at_level(logging.ERROR, logger="orders-worker"):
        main.handle_message(message)
    message.ack.assert_called_once()
    assert caplog.records[0].levelname == "ERROR"
