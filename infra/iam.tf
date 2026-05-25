# ── EC2 instance role ─────────────────────────────────────────────────────────
# EC2 instance profile provides auto-rotating credentials via IMDS — no keys on disk.

resource "aws_iam_role" "hermes" {
  name = "hermes-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.hermes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Scoped inline policy — expand deliberately as skills are added
resource "aws_iam_role_policy" "hermes_ssm_parameters" {
  name = "hermes-ssm-parameters"
  role = aws_iam_role.hermes.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/hermes/*"
    }]
  })
}

resource "aws_iam_role_policy" "hermes_ssm_send_command" {
  name = "hermes-ssm-send-command"
  role = aws_iam_role.hermes.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:SendCommand", "ssm:GetCommandInvocation"]
      Resource = [
        "arn:aws:ec2:eu-north-1:575108949077:instance/i-0f94c1bdc56033056",
        "arn:aws:ssm:eu-north-1::document/AWS-RunShellScript",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "hermes" {
  name = "hermes-instance-profile"
  role = aws_iam_role.hermes.name
}

# ── DLM role for automated AMI snapshots ──────────────────────────────────────

resource "aws_iam_role" "dlm" {
  name = "hermes-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm_full" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRoleForAMIManagement"
}
