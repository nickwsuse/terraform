############################# T E R R A F O R M #############################
# use aws provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.4.0"
    }
    local = {
      source = "hashicorp/local"
      version = "2.4.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "2.10.1"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.21.1"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

provider "local" {
  # Configuration options
}

provider "helm" {
  # kube config location to be used by helm to connect to the cluster
  kubernetes {
    config_path = "${var.kubeconfig_path}/kube_config_${var.rke_config_filename}"
  }
}

############################# E C 2   I N F R A S T R U C T U R E #############################
############################# I N S T A N C E S #############################
# create 3 instances 
resource "aws_instance" "cluster" {
  count = 3
  ami                    = var.aws_ami
  instance_type          = var.aws_instance_type
  subnet_id              = var.aws_subnet_a
  vpc_security_group_ids = [var.aws_security_group]
  key_name               = var.aws_key_name

  root_block_device {
    volume_size = var.aws_instance_size
  }

  tags = {
    Name        = "${var.aws_prefix}-${count.index}"
    Owner       = var.aws_owner_tag
    DoNotDelete = var.aws_do_not_delete_tag
  }
}

############################# L O A D   B A L A N C I N G #############################
# create a target group for 80
resource "aws_lb_target_group" "aws_lb_target_group_80" {
  name        = "${var.aws_prefix}-80"
  port        = 80
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.aws_vpc
  health_check {
    protocol          = "TCP"
    port              = "traffic-port"
    healthy_threshold = 3
    interval          = 10
  }
}

# create a target group for 443
resource "aws_lb_target_group" "aws_lb_target_group_443" {
  name        = "${var.aws_prefix}-443"
  port        = 443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.aws_vpc
  health_check {
    protocol          = "TCP"
    port              = 443
    healthy_threshold = 3
    interval          = 10
  }
}

# attach instances to the target group 80
resource "aws_lb_target_group_attachment" "attach_tg_80" {
  count = length(aws_instance.cluster)
  target_group_arn = aws_lb_target_group.aws_lb_target_group_80.arn
  target_id        = aws_instance.cluster[count.index].id
  port             = 80
}

# attach instances to the target group 443
resource "aws_lb_target_group_attachment" "attach_tg_443" {
  count = length(aws_instance.cluster)
  target_group_arn = aws_lb_target_group.aws_lb_target_group_443.arn
  target_id        = aws_instance.cluster[count.index].id
  port             = 443
}

# create a load balancer
resource "aws_lb" "aws_lb" {
  load_balancer_type = "network"
  name               = "${var.aws_prefix}-lb"
  internal           = false
  ip_address_type    = "ipv4"
  subnets            = [var.aws_subnet_a, var.aws_subnet_b, var.aws_subnet_c]
}

# add a listener for port 80
resource "aws_lb_listener" "aws_lb_listener_80" {
  load_balancer_arn = aws_lb.aws_lb.arn
  port              = "80"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aws_lb_target_group_80.arn
  }
}

# add a listener for port 443
resource "aws_lb_listener" "aws_lb_listener_443" {
  load_balancer_arn = aws_lb.aws_lb.arn
  port              = "443"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aws_lb_target_group_443.arn
  }
}

############################# R O U T E   5 3 #############################
# find route 53 zone id 
data "aws_route53_zone" "zone" {
  name = var.aws_route_zone_name
}

# create a route53 record using the aws_instance
resource "aws_route53_record" "route_53_record" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = var.aws_prefix
  type    = "CNAME"
  ttl     = "300"
  records = [aws_lb.aws_lb.dns_name]
}

############################# K U B E R N E T E S #############################
############################# R K E   C L U S T E R #############################
###### OUTPUT INSTANCE INFO TO RKE CONFIG FILE ######
resource "local_file" "create_rke_config"{
    # set path to ssh private key so rke can ssh into each node for provisioning
    # kubernetes_version is not required, if null rke uses latest
    content = <<EOT
ssh_key_path: ${var.ssh_private_key_path}
kubernetes_version: ${var.k8s_version}

nodes:
- address: ${aws_instance.cluster[0].public_ip}
  internal_address: ${aws_instance.cluster[0].private_ip}
  user: ${var.cluster_user}
  role: ${var.cluster_roles}

- address: ${aws_instance.cluster[1].public_ip}
  internal_address: ${aws_instance.cluster[1].private_ip}
  user: ${var.cluster_user}
  role: ${var.cluster_roles}

- address: ${aws_instance.cluster[2].public_ip}
  internal_address: ${aws_instance.cluster[2].private_ip}
  user: ${var.cluster_user}
  role: ${var.cluster_roles}
    EOT
    filename = var.rke_config_filename
}

# wait for one minute to ensure clusters are ready for rke up command
resource "time_sleep" "wait_for_cluster_ready" {
  create_duration = "60s"

  depends_on = [aws_instance.cluster]
}

# rather than using the rke tf provider, run the rke up command using the config file generated above
resource "null_resource" "rke_up"{
  depends_on = [time_sleep.wait_for_cluster_ready]
  provisioner "local-exec"{
    command = "rke up --config ${local_file.create_rke_config.filename}"
  }

  provisioner "local-exec"{
    command = "export KUBECONFIG=${var.kubeconfig_path}/kube_config_${var.rke_config_filename}"
  }

    provisioner "local-exec"{
    command = "kubectl create namespace cattle-system"
  }
}

############################# H E L M #############################
# install certs
# resource "kubernetes_namespace" "cattle_system"{
#   metadata {
#     name = "cattle-system"
#   }

#   depends_on = [null_resource.rke_up]
# }

resource "kubernetes_secret" "tls" {
  metadata {
    name = "tls-rancher-ingress"
    namespace = "cattle-system"
  }

  data = {
    "tls.crt" = file(var.tls_cert)
    "tls.key" = file(var.tls_key)
  }

  type = "kubernetes.io/tls"

  # wait for cluster and namespace ready
  depends_on = [null_resource.rke_up]
}

# install rancher
resource "helm_release" "rancher" {
  name       = "rancher"
  repository = "https://releases.rancher.com/server-charts/latest"
  chart      = "rancher"
  version    = var.rancher_chart_version
  create_namespace = "true"
  namespace = "cattle-system"

  set {
    name  = "hostname"
    value = aws_route53_record.route_53_record.fqdn
  }

  # Uncomment if you're going to use an image tag such as v2.7-head
  # set {
  #   name  = "rancherImageTag"
  #   value = var.rancher_tag_version
  # }

  set {
    name  = "bootstrapPassword"
    value = var.rancher_password
  }

  set{
    name = "ingress.tls.source"
    value = "secret"
  }

  # wait for certs to be installed first
  depends_on = [ 
    kubernetes_secret.tls
  ]
}

############################# V A R I A B L E S #############################
# not all variables listed below are needed for this set up to work
# values for these variables are stored in a `variables.sh` file (see README)

# aws variables
variable "aws_prefix" {}
variable "aws_region" {}
variable "aws_access_key" {}
variable "aws_secret_key" {}
variable "aws_ami" {}
variable "aws_instance_type" {}
variable "aws_subnet_a" {}
variable "aws_subnet_b" {}
variable "aws_subnet_c" {}
variable "aws_security_group" {}
variable "aws_jenkins_security_group" {}
variable "aws_key_name" {}
variable "aws_instance_size" {}
variable "aws_vpc" {}
variable "aws_route_zone_name" {}
variable "aws_owner_tag" {}
variable "aws_do_not_delete_tag" {}

# ssh variables
variable "ssh_private_key_path" {}

# rke variables
variable "k8s_version" {}
variable "cluster_user" {}
variable "cluster_roles" {}
variable "rke_config_filename" {}
variable "kubeconfig_path" {}

# rancher variables
variable "rancher_tag_version" {}
variable "rancher_chart_version" {}
variable "rancher_password" {}
variable "tls_cert" {}
variable "tls_key" {}