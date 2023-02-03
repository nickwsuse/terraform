############################# T E R R A F O R M #############################
# use aws provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.74.0"
    }
    rke = {
      source = "rancher/rke"
      version = "1.3.4"
    }
    local = {
      source = "hashicorp/local"
      version = "2.1.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "2.4.1"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.17.0"
    }

    null = {
      source = "hashicorp/null"
      version = "3.2.1"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

provider "rke" {
  # Configuration options
}

provider "local" {
  # Configuration options
}

provider "helm" {
  # Configuration options
  # kube config location to be used by helm to connect to the cluster
    kubernetes {
    config_path = "${local_file.kube_config.filename}"
  }
}

provider "null" {
  # Configuration options
}

provider "kubernetes" {
  # configuration options
  config_path = "${local_file.kube_config.filename}"
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



resource "null_resource" "set_initial_state" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = "echo \"0\" > counter"
  }
}

variable "index" {
  type = number
  default = 1 
}

resource "null_resource" "wait" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = "while [[ $(cat counter) != \"${var.index}\" ]]; do sleep 5; done; sleep 3;"
  }
}






# The primary use-case for the null resource is as a do-nothing container
# for arbitrary actions taken by a provisioner.
#
# Due to the triggers map, the null_resource will be replaced 
# each time the instance ids # change, and thus the remote-exec 
# provisioner will be re-run.
resource "null_resource" "cluster" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers = {
    cluster_instance_ids = join(",", aws_instance.cluster.*.id)
  }
}

# print the instance info
output "instance_public_ip" {
  value = [for instance in aws_instance.cluster : instance.public_ip]
}
output "instance_private_ip" {
  value = [for instance in aws_instance.cluster : instance.private_ip]
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
  count            = length(aws_instance.cluster)
  target_group_arn = aws_lb_target_group.aws_lb_target_group_80.arn
  target_id        = aws_instance.cluster[count.index].id
  port             = 80
}

# attach instances to the target group 443
resource "aws_lb_target_group_attachment" "attach_tg_443" {
  count            = length(aws_instance.cluster)
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

# print route53 full record
output "route_53_record" {
  value = aws_route53_record.route_53_record.fqdn
}

############################# K U B E R N E T E S #############################
############################# R K E   C L U S T E R #############################
# create a rke cluster
resource "rke_cluster" "cluster" {
  ssh_key_path = var.ssh_private_key_path
  kubernetes_version = var.k8s_version

  nodes {
    address          = aws_instance.cluster[0].public_ip
    internal_address = aws_instance.cluster[0].private_ip
    user             = "ubuntu"
    role             = ["controlplane", "worker", "etcd"]
  }
    nodes {
    address = aws_instance.cluster[1].public_ip
    internal_address = aws_instance.cluster[1].private_ip
    user    = "ubuntu"
    role    = ["controlplane", "worker", "etcd"]
  }
    nodes {
    address = aws_instance.cluster[2].public_ip
    internal_address = aws_instance.cluster[2].private_ip
    user    = "ubuntu"
    role    = ["controlplane", "worker", "etcd"]
  } 
}

############################# L O C A L   S E T U P #############################
# save kubeconfig file on the local 
resource "local_file" "kube_config" {
  depends_on  = [rke_cluster.cluster]
  content     = "${rke_cluster.cluster.kube_config_yaml}"
  filename    = var.kube_config_path
}

############################# H E L M #############################
resource "kubernetes_namespace" "cattle_system"{
  metadata {
    name = "cattle-system"
  }

  depends_on = [
    local_file.kube_config
  ]
}

resource "kubernetes_secret" "tls" {
  metadata {
    name = "tls-rancher-ingress"
    namespace = kubernetes_namespace.cattle_system.metadata[0].name
  }

  data = {
    "tls.crt" = file(var.tls_cert)
    "tls.key" = file(var.tls_key)
  }

  type = "kubernetes.io/tls"

  # wait for kube config file to be created
  depends_on = [ 
    kubernetes_namespace.cattle_system
  ]
}

# install rancher
resource "helm_release" "rancher" {
  depends_on = [rke_cluster.cluster]
  name       = "rancher"
  repository = "https://releases.rancher.com/server-charts/latest"
  chart      = "rancher"
  version    = var.rancher_chart_version
  namespace  = "cattle-system"

  set {
    name  = "hostname"
    value = aws_route53_record.route_53_record.fqdn
  } 
  
  set {
    name  = "rancherImageTag"
    value = var.rancher_tag_version
  }

   set {
    name  = "bootstrapPassword"
    value = var.rancher_password
  }

  set{
    name = "ingress.tls.source"
    value = "secret"
  }
}

############################# V A R I A B L E S #############################
# not all variables listed below are needed for this set up to work
# values for these variables are stored in a `variables.sh` file (see README)
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
variable "aws_key_name" {}
variable "aws_instance_size" {}
variable "aws_vpc" {}
variable "aws_route_zone_name" {}
variable "aws_owner_tag" {}
variable "aws_do_not_delete_tag" {}
variable "ssh_private_key_path" {}
variable "k8s_version" {}
variable "kube_config_path" {}
variable "rancher_tag_version" {}
variable "rancher_chart_version" {}
variable "rancher_password" {}
variable "tls_cert" {}
variable "tls_key" {}