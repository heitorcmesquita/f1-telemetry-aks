"""OpenF1 race-day producer.

This script polls the OpenF1 public API and publishes telemetry events into Azure Event Hubs.

Expected environment variables:
  EVENTHUB_CONNECTION_STRING - Event Hubs namespace connection string (required)
  EVENTHUB_POSITIONS         - Event Hub name for position events (required)
  EVENTHUB_LAPS              - Event Hub name for lap events (required)
  EVENTHUB_TELEMETRY         - Event Hub name for telemetry events (required)
  EVENTHUB_WEATHER           - Event Hub name for weather events (required)
  POLL_INTERVAL_SECONDS      - How often to poll the API (default: 10)
  LOOKBACK_SECONDS           - How far back in time to query (default: 30)
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from datetime import datetime, timedelta, timezone

import requests
from azure.eventhub import EventData, EventHubProducerClient


def get_env(name: str, required: bool = True, default: str | None = None) -> str | None:
    value = os.getenv(name, default)
    if required and not value:
        logging.error("Missing required environment variable: %s", name)
        sys.exit(1)
    return value


def create_eventhub_clients(conn_str: str, hub_names: dict[str, str]) -> dict[str, EventHubProducerClient]:
    return {
        name: EventHubProducerClient.from_connection_string(conn_str, eventhub_name=hub)
        for name, hub in hub_names.items()
    }


def chunked(iterable: list, size: int):
    for i in range(0, len(iterable), size):
        yield iterable[i : i + size]


def fetch_json(url: str, timeout: int = 10) -> list[dict]:
    try:
        resp = requests.get(url, timeout=timeout)
        resp.raise_for_status()
        return resp.json() or []
    except Exception as exc:  # noqa: BLE001
        logging.warning("HTTP fetch failed (%s): %s", url, exc)
        return []


def send_batch(
    client: EventHubProducerClient,
    name: str,
    data: list[dict],
    retry_attempts: int = 3,
    chunk_size: int = 50,
) -> int:
    if not data:
        logging.debug("[%s] no data to send", name)
        return 0

    total_sent = 0
    for chunk in chunked(data, chunk_size):
        for attempt in range(1, retry_attempts + 1):
            try:
                batch = client.create_batch()
                for item in chunk:
                    batch.add(EventData(json.dumps(item)))
                client.send_batch(batch)
                total_sent += len(chunk)
                break
            except Exception as exc:  # noqa: BLE001
                logging.warning("[%s] attempt %d/%d failed: %s", name, attempt, retry_attempts, exc)
                if attempt == retry_attempts:
                    logging.error("[%s] giving up after %d attempts", name, retry_attempts)
                else:
                    time.sleep(2)
    return total_sent


def get_latest_session_key() -> str | None:
    url = "https://api.openf1.org/v1/sessions?session_key=latest"
    sessions = fetch_json(url)
    if not isinstance(sessions, list) or not sessions:
        return None
    return sessions[0].get("session_key")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")

    conn_str = get_env("EVENTHUB_CONNECTION_STRING")
    hubs = {
        "positions": get_env("EVENTHUB_POSITIONS"),
        "laps": get_env("EVENTHUB_LAPS"),
        "telemetry": get_env("EVENTHUB_TELEMETRY"),
        "weather": get_env("EVENTHUB_WEATHER"),
    }

    poll_interval = int(get_env("POLL_INTERVAL_SECONDS", required=False, default="10"))
    lookback_seconds = int(get_env("LOOKBACK_SECONDS", required=False, default="30"))

    clients = create_eventhub_clients(conn_str, hubs)

    try:
        logging.info("Race day producer started. Polling every %s seconds...", poll_interval)
        while True:
            session_key = get_latest_session_key()
            if not session_key:
                logging.info("No active session found. Retrying in %s seconds...", poll_interval)
                time.sleep(poll_interval)
                continue

            now = datetime.now(timezone.utc)
            since = (now - timedelta(seconds=lookback_seconds)).strftime("%Y-%m-%dT%H:%M:%S")
            logging.debug("Using lookback timestamp: %s", since)

            data_urls = {
                "positions": f"https://api.openf1.org/v1/position?session_key={session_key}&date>{since}",
                "laps": f"https://api.openf1.org/v1/laps?session_key={session_key}&date_start>{since}",
                "telemetry": f"https://api.openf1.org/v1/car_data?session_key={session_key}&date>{since}",
                "weather": f"https://api.openf1.org/v1/weather?session_key={session_key}&date>{since}",
            }

            for name, url in data_urls.items():
                events = fetch_json(url)
                sent = send_batch(clients[name], name, events)
                logging.info("%s: sent %d events", name, sent)

            time.sleep(poll_interval)
    except KeyboardInterrupt:
        logging.info("Interrupted by user, shutting down...")
    finally:
        for name, client in clients.items():
            client.close()
        logging.info("All Event Hubs clients closed.")


if __name__ == "__main__":
    main()
