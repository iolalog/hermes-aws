import json
import subprocess

import boto3
import pytest


def _terraform_output() -> dict:
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd="infra",
        capture_output=True,
        text=True,
        check=True,
    )
    raw = json.loads(result.stdout)
    return {k: v["value"] for k, v in raw.items()}


@pytest.fixture(scope="session")
def tf_output():
    return _terraform_output()


@pytest.fixture(scope="session")
def aws_region(tf_output):
    region = tf_output.get("aws_region") or "eu-north-1"
    return region


@pytest.fixture(scope="session")
def ssm_client(aws_region):
    return boto3.client("ssm", region_name=aws_region)


@pytest.fixture(scope="session")
def ec2_client(aws_region):
    return boto3.client("ec2", region_name=aws_region)


@pytest.fixture(scope="session")
def iam_client(aws_region):
    return boto3.client("iam", region_name=aws_region)


@pytest.fixture(scope="session")
def managed_instance_id(tf_output):
    instance_id = tf_output.get("instance_id")
    assert instance_id, "instance_id not found in terraform output"
    return instance_id
