"""Synchronize the scholarship database and application Secrets from SSM SecureString parameters."""

import argparse
import base64
import json
import secrets
import string
import subprocess
import sys
from time import sleep

import boto3
from botocore.exceptions import BotoCoreError, ClientError

NAMESPACE = "dv-ayan-kassen-1951"
PREFIX = f"/{NAMESPACE}/platform/"
DB_KEYS = ("postgres-password", "admin-password", "rw-password", "ro-password")
KEYS = (*DB_KEYS, "secret-key")


def generate_value() -> str:
    """Generate a high-entropy, file-safe value accepted by PostgreSQL and the app."""
    return (
        secrets.choice(string.ascii_uppercase)
        + secrets.choice(string.ascii_lowercase)
        + secrets.choice(string.digits)
        + secrets.token_urlsafe(32)
    )


def read_values(ssm) -> dict[str, str]:
    response = ssm.get_parameters(Names=[PREFIX + key for key in KEYS], WithDecryption=True)
    result = {}
    for parameter in response["Parameters"]:
        key = parameter["Name"].removeprefix(PREFIX)
        if key not in KEYS or parameter["Name"] != PREFIX + key or parameter["Type"] != "SecureString":
            raise ValueError("Expected a SecureString under the project parameter prefix")
        value = parameter["Value"]
        if not value or value.strip() != value or any(c in value for c in "\r\n\0"):
            raise ValueError(f"{key} must contain a single value suitable for mounting as a file")
        if key == "secret-key":
            if len(value) < 32:
                raise ValueError("secret-key must have at least 32 characters")
        elif (
            len(value) < 16
            or not any(c in string.ascii_uppercase for c in value)
            or not any(c in string.ascii_lowercase for c in value)
            or not any(c in string.digits for c in value)
        ):
            raise ValueError(f"{key} does not meet the project database password policy")
        result[key] = value
    return result


def load_parameters(ssm, *, initialize: bool = False) -> dict[str, str]:
    """Return all five values; initialization only creates previously absent parameters."""
    values = read_values(ssm)
    missing = [key for key in KEYS if key not in values]
    if not missing:
        return values
    if not initialize:
        raise ValueError("Missing SSM parameters: " + ", ".join(missing) + ". Use --initialize on first deployment.")
    for key in missing:
        try:
            ssm.put_parameter(Name=PREFIX + key, Type="SecureString", Value=generate_value(), Overwrite=False)
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ParameterAlreadyExists":
                raise
    # A concurrent initializer may have won a create; only synchronize values fetched from SSM.
    for delay in (0, 1, 2, 4):
        if delay:
            sleep(delay)
        values = read_values(ssm)
        if len(values) == len(KEYS):
            return values
    raise RuntimeError("SSM has not returned all five parameters yet. Rerun the sync.")


def kubernetes_secrets(values: dict[str, str]) -> dict:
    """Return an API List suitable for kubectl server-side apply on standard input."""
    items = []
    for name, keys in (("postgres-credentials", DB_KEYS), ("app-credentials", ("secret-key", "rw-password"))):
        items.append(
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": f"{NAMESPACE}-{name}", "namespace": NAMESPACE},
                "type": "Opaque",
                "data": {key: base64.b64encode(values[key].encode()).decode("ascii") for key in keys},
            }
        )
    return {"apiVersion": "v1", "kind": "List", "items": items}


def run_kubectl(args: list[str], payload: bytes | None = None) -> None:
    # Suppress response bodies: API validation errors can include submitted Secret data.
    result = subprocess.run(args, input=payload, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)  # noqa: S603
    if result.returncode:
        raise RuntimeError(f"kubectl exited with code {result.returncode}. Check cluster access, namespace and RBAC.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initialize", action="store_true", help="create missing parameters once")
    parser.add_argument("--context", help="explicit local kubectl context")
    parser.add_argument("transport", nargs=argparse.REMAINDER, help="alternative kubectl command after --")
    args = parser.parse_args()
    transport = args.transport
    if transport and transport[0] == "--":
        transport = transport[1:]
    if bool(args.context) == bool(transport):
        parser.error("provide either --context NAME or an explicit kubectl command after --")
    kubectl = transport or ["kubectl", "--context", args.context]
    run_kubectl([*kubectl, "get", "namespace", NAMESPACE, "-o", "name"])
    client = boto3.client("ssm", region_name="us-east-1")
    values = load_parameters(client, initialize=args.initialize)
    payload = json.dumps(kubernetes_secrets(values)).encode()
    run_kubectl(
        [*kubectl, "apply", "--server-side", "--force-conflicts", "--field-manager=platform-secret-sync", "-f", "-"],
        payload,
    )
    print(f"Synchronized the database and application Secrets in {NAMESPACE}.")


if __name__ == "__main__":
    try:
        main()
    except ClientError as error:
        sys.exit("SSM request failed: " + error.response["Error"]["Code"])
    except BotoCoreError as error:
        sys.exit("AWS client failed: " + type(error).__name__)
    except (OSError, RuntimeError, ValueError) as error:
        sys.exit(str(error))
