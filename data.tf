###############################################################################
# Account / partition / region context used to build derived ARNs and IAM
# confused-deputy conditions throughout the module.
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

# NOTE: archive_file.invoker_zip is intentionally deferred to checklist Item F,
# which also creates files/invoker/index.py. Declaring the data source before
# the source file exists would fail terraform validate.
