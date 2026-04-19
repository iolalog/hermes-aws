resource "aws_ssm_document" "hermes_status" {
  name            = "HermesStatus"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Show Hermes gateway status: service state, recent logs."
    parameters    = {}
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "StatusHermes"
        inputs = {
          runCommand = ["/usr/local/bin/hermes-status"]
        }
      }
    ]
  })
}

resource "aws_ssm_document" "hermes_restart" {
  name            = "HermesRestart"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Restart the Hermes gateway service."
    parameters    = {}
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "RestartHermes"
        inputs = {
          runCommand = ["systemctl restart hermes-gateway && sleep 3 && systemctl status hermes-gateway --no-pager"]
        }
      }
    ]
  })
}
