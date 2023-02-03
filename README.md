This is a template for the `variables.sh` file with environment variables for scripts to use. You will need to fill out with your values (not all values are required, just fill out what you need) and run the script `source variables.sh` before running `terraform apply`
```
# aws creds
export TF_VAR_aws_region=
export TF_VAR_aws_access_key=
export TF_VAR_aws_secret_key=

#######################################################################

# aws instance info
# ec2 info
export TF_VAR_aws_prefix=
export TF_VAR_aws_ami=ami-
export TF_VAR_aws_instance_type=
export TF_VAR_aws_subnet_a=
export TF_VAR_aws_subnet_b=
export TF_VAR_aws_subnet_c=
export TF_VAR_aws_security_group=
export TF_VAR_aws_key_name=
export TF_VAR_aws_instance_size=
export TF_VAR_aws_vpc=
export TF_VAR_aws_owner_tag=
export TF_VAR_aws_do_not_delete_tag=

# route 53 info
export TF_VAR_aws_route_zone_name=

# cert info
# export TV_VAR_tls_server_url=
export TF_VAR_tls_cert=
export TF_VAR_tls_key=
export TF_VAR_tls_chain=


#######################################################################

# ssh info
export TF_VAR_ssh_private_key_path=

# k8s info
export TF_VAR_k8s_version=
export TF_VAR_kube_config_path=

#######################################################################

# rancher info
export TF_VAR_rancher_tag_version=
export TF_VAR_rancher_chart_version=
export TF_VAR_rancher_password=

#######################################################################

# index for temp rke solution
export TF_VAR_index=
```
