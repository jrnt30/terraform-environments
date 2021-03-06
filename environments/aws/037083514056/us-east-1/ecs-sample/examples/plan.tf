terraform {
    required_version = ">= 0.11"
    backend "s3" {}
}

provider "aws" {
    alias  = "east"
    region = "us-east-1"
}

provider "aws" {
    region = "${var.region}"
}

variable "region" {
    type = "string"
    default = "us-east-1"
}

variable "project" {
    type = "string"
    default = "Examples"
}

variable "creator" {
    type = "string"
    default = "kurr@kurron.org"
}

variable "environment" {
    type = "string"
    default = "examples"
}

variable "ec2_instance_limit" {
    type = "string"
    default = "0"
}

variable "ingress_cidrs" {
    type = "list"
    default = ["64.222.174.146/32","98.216.147.13/32"]
}

variable "api_domain_name" {
    type = "string"
    default = "examples.transparent.engineering"
}

variable "domain_name" {
    type = "string"
    default = "transparent.engineering"
}

variable "alpha_service_name" {
    type = "string"
    default = "alpha"
}

variable "bravo_service_name" {
    type = "string"
    default = "bravo"
}

variable "charlie_service_name" {
    type = "string"
    default = "charlie"
}

variable "instance_type" {
    type = "string"
    default = "m3.medium"
}

data "terraform_remote_state" "vpc" {
    backend = "s3"
    config {
        bucket = "transparent-test-terraform-state"
        key    = "us-east-1/all/examples/networking/vpc/terraform.tfstate"
        region = "us-east-1"
    }
}

data "terraform_remote_state" "security-groups" {
    backend = "s3"
    config {
        bucket = "transparent-test-terraform-state"
        key    = "us-east-1/all/examples/compute/security-groups/terraform.tfstate"
        region = "us-east-1"
    }
}

data "terraform_remote_state" "iam" {
    backend = "s3"
    config {
        bucket = "transparent-test-terraform-state"
        key    = "global/all/examples/security/iam/terraform.tfstate"
        region = "us-east-1"
    }
}

data "terraform_remote_state" "load_balancer" {
    backend = "s3"
    config {
        bucket = "transparent-test-terraform-state"
        key    = "us-east-1/all/examples/compute/load-balancer/terraform.tfstate"
        region = "us-east-1"
    }
}

data "aws_acm_certificate" "certificate" {
    provider = "aws.east"
    domain   = "*.${var.domain_name}"
    statuses = ["ISSUED"]
}

data "aws_route53_zone" "selected" {
    provider     = "aws.east"
    name         = "${var.domain_name}."
    private_zone = false
}

module "bastion" {
    source                      = "kurron/bastion/aws"
    region                      = "${var.region}"
    project                     = "${var.project}"
    creator                     = "${var.creator}"
    environment                 = "${var.environment}"
    freetext                    = "Have at least one instance available for SSH access"
    instance_type               = "t2.nano"
    ssh_key_name                = "Bastion"
    min_size                    = "1"
    max_size                    = "2"
    cooldown                    = "60"
    health_check_grace_period   = "300"
    desired_capacity            = "1"
    scale_down_desired_capacity = "0"
    scale_down_min_size         = "0"
    scale_up_cron               = "0 12 * * MON-FRI"
    scale_down_cron             = "0 00 * * SUN-SAT"
    public_ssh_key              = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCv70t6ne08BNDf3aAQOdhe7h1NssBGPEucjKA/gL9vXpclGBqZnvOiQltKrOeOLzcbDJYDMYIJCwtoq7R/3RLOLDSi5OChhFtyjGULkIxa2dJgKXWPz04E1260CMqkKcgrQ1AaYA122zepakE7d+ysMoKSbQSVGaleZ6aFxe8DfKMzAFFra44tF5JUSMpuqwwI/bKEyehX/PDMNe/GWUTk+5c4XC6269NbaeWMivH2CiYPPBXblj6IT+QhBY5bTEFT57GmUff1sJOyhGN+9kMhlsSrXtp1A5wGiZ8nhoUduphzP3h0RNbRVA4mmI4jMnOF51uKbOvNk3Y79FSIS9Td Access to Bastion box"
    security_group_ids          = ["${data.terraform_remote_state.security-groups.bastion_id}"]
    subnet_ids                  = "${data.terraform_remote_state.vpc.public_subnet_ids}"
}

module "ecs" {
    source                           = "kurron/ecs/aws"
    region                           = "${var.region}"
    name                             = "Example_Cluster"
    project                          = "${var.project}"
    purpose                          = "Docker scheduler"
    creator                          = "${var.creator}"
    environment                      = "${var.environment}"
    freetext                         = "Workers are based on spot instances."
    ami_regexp                       = "^amzn-ami-.*-amazon-ecs-optimized$"
    instance_type                    = "${var.instance_type}"
    instance_profile                 = "${data.terraform_remote_state.iam.ecs_profile_id}"
    ssh_key_name                     = "${module.bastion.ssh_key_name}"
    security_group_ids               = ["${data.terraform_remote_state.security-groups.ec2_id}"]
    ebs_optimized                    = "false"
    spot_price                       = "0.0670"
    cluster_min_size                 = "1"
    cluster_desired_size             = "${length( data.terraform_remote_state.vpc.public_subnet_ids )}"
    cluster_max_size                 = "${length( data.terraform_remote_state.vpc.public_subnet_ids )}"
    cooldown                         = "90"
    health_check_grace_period        = "300"
    subnet_ids                       = "${data.terraform_remote_state.vpc.public_subnet_ids}"
    scale_up_cron                    = "0 13 * * MON-FRI"
    scale_down_cron                  = "0 01 * * SUN-SAT"
    cluster_scaled_down_min_size     = "0"
    cluster_scaled_down_desired_size = "0"
    cluster_scaled_down_max_size     = "0"
}

data "template_file" "alpha_service_definition" {
    template = "${file("${path.module}/files/alpha-task-definition.json.template")}"
    vars {
        service_name = "${var.alpha_service_name}"
    }
}

resource "aws_ecs_task_definition" "alpha" {
    family                = "${var.alpha_service_name}"
    container_definitions = "${data.template_file.alpha_service_definition.rendered}"
    network_mode          = "bridge"
}

module "alpha_service" {
     source = "kurron/ecs-service/aws"

     region                             = "${var.region}"
     name                               = "${var.alpha_service_name}"
     project                            = "${var.project}"
     purpose                            = "Just an example service"
     creator                            = "${var.creator}"
     environment                        = "${var.environment}"
     freetext                           = "Dumps the current environment over REST"

     enable_stickiness                  = "Yes"
     health_check_interval              = "30"
     health_check_path                  = "/${var.alpha_service_name}/operations/health"
     health_check_timeout               = "5"
     health_check_healthy_threshold     = "5"
     unhealthy_threshold                = "2"
     matcher                            = "200-299"

     path_pattern                       = "/${var.alpha_service_name}*"
     rule_priority                      = "1"
     vpc_id                             = "${data.terraform_remote_state.vpc.vpc_id}"
     secure_listener_arn                = "${data.terraform_remote_state.load_balancer.secure_listener_arn}"
     insecure_listener_arn              = "${data.terraform_remote_state.load_balancer.insecure_listener_arn}"

     task_definition_arn                = "${aws_ecs_task_definition.alpha.arn}"
     desired_count                      = "7"
     cluster_arn                        = "${module.ecs.cluster_arn}"
     iam_role                           = "${data.terraform_remote_state.iam.ecs_role_arn}"
     deployment_maximum_percent         = "200"
     deployment_minimum_healthy_percent = "50"
     container_name                     = "${var.alpha_service_name}"
     container_port                     = "8080"
     container_protocol                 = "HTTP"

     placement_strategies = [
         {
             "type"  = "spread"
             "field" = "attribute:ecs.availability-zone"
         }
     ]
     placement_constraints    = [
         {
             "type" = "distinctInstance"
         },
         {
             "type"       = "memberOf"
             "expression" = "attribute:ecs.instance-type == ${var.instance_type}"
         }
     ]
}

data "template_file" "bravo_service_definition" {
    template = "${file("${path.module}/files/bravo-task-definition.json.template")}"
    vars {
        service_name = "${var.bravo_service_name}"
    }
}

resource "aws_ecs_task_definition" "bravo" {
    family                = "${var.bravo_service_name}"
    container_definitions = "${data.template_file.bravo_service_definition.rendered}"
    network_mode          = "bridge"
}

module "bravo_service" {
     source = "kurron/ecs-service/aws"

     region                             = "${var.region}"
     name                               = "${var.bravo_service_name}"
     project                            = "${var.project}"
     purpose                            = "Just an example service"
     creator                            = "${var.creator}"
     environment                        = "${var.environment}"
     freetext                           = "Dumps the current environment over REST"

     enable_stickiness                  = "Yes"
     health_check_interval              = "30"
     health_check_path                  = "/${var.bravo_service_name}/operations/health"
     health_check_timeout               = "5"
     health_check_healthy_threshold     = "5"
     unhealthy_threshold                = "2"
     matcher                            = "200-299"

     path_pattern                       = "/${var.bravo_service_name}*"
     rule_priority                      = "2"
     vpc_id                             = "${data.terraform_remote_state.vpc.vpc_id}"
     secure_listener_arn                = "${data.terraform_remote_state.load_balancer.secure_listener_arn}"
     insecure_listener_arn              = "${data.terraform_remote_state.load_balancer.insecure_listener_arn}"

     task_definition_arn                = "${aws_ecs_task_definition.bravo.arn}"
     desired_count                      = "8"
     cluster_arn                        = "${module.ecs.cluster_arn}"
     iam_role                           = "${data.terraform_remote_state.iam.ecs_role_arn}"
     deployment_maximum_percent         = "200"
     deployment_minimum_healthy_percent = "50"
     container_name                     = "${var.bravo_service_name}"
     container_port                     = "8080"
     container_protocol                 = "HTTP"

     placement_strategies = [
         {
             "type"  = "spread"
             "field" = "attribute:ecs.availability-zone"
         },
         {
             "type"  = "binpack"
             "field" = "memory"
         }
     ]
     placement_constraints    = [
         {
             "type"       = "memberOf"
             "expression" = "attribute:ecs.instance-type == ${var.instance_type}"
         }
     ]
}

data "template_file" "charlie_service_definition" {
    template = "${file("${path.module}/files/charlie-task-definition.json.template")}"
    vars {
        service_name = "${var.charlie_service_name}"
    }
}

resource "aws_ecs_task_definition" "charlie" {
    family                = "${var.charlie_service_name}"
    container_definitions = "${data.template_file.charlie_service_definition.rendered}"
    network_mode          = "bridge"
}

module "charlie_service" {
     source = "kurron/ecs-service/aws"

     region                             = "${var.region}"
     name                               = "${var.charlie_service_name}"
     project                            = "${var.project}"
     purpose                            = "Just an example service"
     creator                            = "${var.creator}"
     environment                        = "${var.environment}"
     freetext                           = "Dumps the current environment over REST"

     enable_stickiness                  = "Yes"
     health_check_interval              = "30"
     health_check_path                  = "/${var.charlie_service_name}/operations/health"
     health_check_timeout               = "5"
     health_check_healthy_threshold     = "5"
     unhealthy_threshold                = "2"
     matcher                            = "200-299"

     path_pattern                       = "/${var.charlie_service_name}*"
     rule_priority                      = "3"
     vpc_id                             = "${data.terraform_remote_state.vpc.vpc_id}"
     secure_listener_arn                = "${data.terraform_remote_state.load_balancer.secure_listener_arn}"
     insecure_listener_arn              = "${data.terraform_remote_state.load_balancer.insecure_listener_arn}"

     task_definition_arn                = "${aws_ecs_task_definition.charlie.arn}"
     desired_count                      = "6"
     cluster_arn                        = "${module.ecs.cluster_arn}"
     iam_role                           = "${data.terraform_remote_state.iam.ecs_role_arn}"
     deployment_maximum_percent         = "200"
     deployment_minimum_healthy_percent = "50"
     container_name                     = "${var.charlie_service_name}"
     container_port                     = "8080"
     container_protocol                 = "HTTP"

     placement_strategies = [
         {
             "type"  = "spread"
             "field" = "attribute:ecs.availability-zone"
         }
     ]
     placement_constraints = []
}
