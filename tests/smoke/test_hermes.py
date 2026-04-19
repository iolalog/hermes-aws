"""
Smoke tests for the Hermes EC2 deployment.

Run after `terraform apply` completes and the bootstrap script has had ~5 min:

    uv run pytest tests/smoke/ -v
"""

import time


class TestSSM:
    def test_instance_online(self, ssm_client, managed_instance_id):
        resp = ssm_client.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [managed_instance_id]}]
        )
        instances = resp["InstanceInformationList"]
        assert instances, f"Instance {managed_instance_id} not found in SSM"
        assert instances[0]["PingStatus"] == "Online", (
            f"Expected Online, got {instances[0]['PingStatus']}"
        )

    def test_hermes_service_active(self, ssm_client, managed_instance_id):
        resp = ssm_client.send_command(
            InstanceIds=[managed_instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": ["systemctl is-active hermes-gateway"]},
        )
        command_id = resp["Command"]["CommandId"]

        for _ in range(12):
            time.sleep(5)
            result = ssm_client.get_command_invocation(
                CommandId=command_id,
                InstanceId=managed_instance_id,
            )
            if result["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
                break

        assert result["Status"] == "Success", (
            f"Command status: {result['Status']}\n"
            f"stdout: {result.get('StandardOutputContent')}\n"
            f"stderr: {result.get('StandardErrorContent')}"
        )
        assert result["StandardOutputContent"].strip() == "active", (
            f"hermes-gateway is not active: {result['StandardOutputContent'].strip()}"
        )


class TestFirewall:
    def test_no_inbound_rules(self, ec2_client):
        resp = ec2_client.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": ["hermes-sg"]}]
        )
        sgs = resp["SecurityGroups"]
        assert sgs, "Security group 'hermes-sg' not found"
        sg = sgs[0]
        assert sg["IpPermissions"] == [], (
            f"Security group has inbound rules — expected none: {sg['IpPermissions']}"
        )

    def test_port_22_not_open(self, ec2_client):
        resp = ec2_client.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": ["hermes-sg"]}]
        )
        sg = resp["SecurityGroups"][0]
        open_ports = set()
        for rule in sg["IpPermissions"]:
            if rule.get("FromPort") is not None:
                open_ports.add(rule["FromPort"])
        assert 22 not in open_ports, (
            "Port 22 is open in security group — it must remain closed"
        )

    def test_imdsv2_enforced(self, ec2_client, managed_instance_id):
        resp = ec2_client.describe_instances(InstanceIds=[managed_instance_id])
        opts = resp["Reservations"][0]["Instances"][0].get("MetadataOptions", {})
        assert opts.get("HttpTokens") == "required", "IMDSv2 must be enforced"


class TestIAMScope:
    def test_ssm_parameters_policy_scoped(self, iam_client):
        """Instance role SSM policy is scoped to /hermes/* only."""
        resp = iam_client.get_role_policy(
            RoleName="hermes-instance-role",
            PolicyName="hermes-ssm-parameters",
        )
        policy = resp["PolicyDocument"]
        for stmt in policy["Statement"]:
            for resource in (
                [stmt["Resource"]]
                if isinstance(stmt["Resource"], str)
                else stmt["Resource"]
            ):
                assert "/hermes/" in resource, (
                    f"SSM policy resource is broader than /hermes/*: {resource}"
                )
