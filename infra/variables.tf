variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-north-1"
}

# ── Peer monitoring (optional) ────────────────────────────────────────────────
# Set these to enable Hermes→peer SSM health checks.

variable "peer_instance_id" {
  description = "EC2 instance ID of the peer agent to monitor (e.g. i-0abc123). Leave empty to skip."
  type        = string
  default     = ""
}

variable "peer_aws_account_id" {
  description = "AWS account ID where the peer instance runs. Defaults to the current account when empty."
  type        = string
  default     = ""
}
