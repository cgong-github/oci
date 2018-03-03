variable "tenancy_ocid" {}
variable "user_ocid" {}
variable "fingerprint" {}
variable "private_key_path" {}
variable "compartment_ocid" {}
variable "region" {}
variable "ssh_public_key" {}

# Choose an Availability Domain
variable "AD" {
    default = "1"
}

variable "InstanceShape" {
    default = "VM.Standard1.2"
}

variable "InstanceImageDisplayName" {
    default = "Oracle-Linux-7.4-2017.10.25-0"
}

variable "vcn_cidr" {
    default = "10.0.0.0/16"
}

variable "mgmt_subnet_cidr" {
    default = "10.0.0.0/24"
}

variable "private_subnet1_cidr" {
    default = "10.0.1.0/24"
}

variable "private_subnet2_cidr" {
    default = "10.0.2.0/24"
}

provider "oci" {
    tenancy_ocid = "${var.tenancy_ocid}"
    user_ocid = "${var.user_ocid}"
    fingerprint = "${var.fingerprint}"
    private_key_path = "${var.private_key_path}"
    region = "${var.region}"
}

data "oci_identity_availability_domains" "ADs" {
    compartment_id = "${var.tenancy_ocid}"
}

resource "oci_core_virtual_network" "CoreVCN" {
    cidr_block = "${var.vcn_cidr}"
    compartment_id = "${var.compartment_ocid}"
    display_name = "mgmt-vcn"
}

resource "oci_core_internet_gateway" "MgmtIG" {
    compartment_id = "${var.compartment_ocid}"
    display_name = "MgmtIG"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"
}

resource "oci_core_route_table" "MgmtRouteTable" {
    compartment_id = "${var.compartment_ocid}"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"
    display_name = "MgmtRouteTable"
    route_rules {
        cidr_block = "0.0.0.0/0"
        network_entity_id = "${oci_core_internet_gateway.MgmtIG.id}"
    }
}

resource "oci_core_security_list" "MgmtSecurityList" {
    compartment_id = "${var.compartment_ocid}"
    display_name = "MgmtSecurityList"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"

    egress_security_rules = [{
        protocol = "all"
        destination = "0.0.0.0/0"
    }]

    ingress_security_rules = [{
        tcp_options {
            "max" = 80
            "min" = 80
        }
        protocol = "6"
        source = "0.0.0.0/0"
    },
    {
        tcp_options {
            "max" = 443
            "min" = 443
        }
        protocol = "6"
        source = "0.0.0.0/0"
    },
	{
        protocol = "all"
        source = "${var.vcn_cidr}"
    },
    {
        protocol = "6"
        source = "0.0.0.0/0"
        tcp_options {
            "min" = 22
            "max" = 22
        }
    },
    {
        protocol = "1"
        source = "0.0.0.0/0"
        icmp_options {
            "type" = 3
            "code" = 4
        }
    }]
}

resource "oci_core_subnet" "MgmtSubnet" {
    availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}"
    cidr_block = "${var.mgmt_subnet_cidr}"
    display_name = "MgmtSubnet"
    compartment_id = "${var.compartment_ocid}"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"
    route_table_id = "${oci_core_route_table.MgmtRouteTable.id}"
    security_list_ids = ["${oci_core_security_list.MgmtSecurityList.id}"]
    dhcp_options_id = "${oci_core_virtual_network.CoreVCN.default_dhcp_options_id}"
}

# Gets the OCID of the image. This technique is for example purposes only. The results of oci_core_images may
# change over time for Oracle-provided images, so the only sure way to get the correct OCID is to supply it directly.
data "oci_core_images" "OLImageOCID" {
    compartment_id = "${var.compartment_ocid}"
    display_name = "${var.InstanceImageDisplayName}"
}

resource "oci_core_instance" "NatInstance" {
    availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}"
    compartment_id = "${var.compartment_ocid}"
    display_name = "NatInstance"
    image = "${lookup(data.oci_core_images.OLImageOCID.images[0], "id")}"
    shape = "${var.InstanceShape}"
    create_vnic_details {
        subnet_id = "${oci_core_subnet.MgmtSubnet.id}"
        skip_source_dest_check = true
    }
    metadata {
        ssh_authorized_keys = "${var.ssh_public_key}"
        user_data = "${base64encode(file("./userdata/user_data.tpl"))}"
    }
    timeouts {
        create = "10m"
    }
}

# Gets a list of VNIC attachments on the instance
data "oci_core_vnic_attachments" "NatInstanceVnics" {
    compartment_id = "${var.compartment_ocid}"
    availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}"
    instance_id = "${oci_core_instance.NatInstance.id}"
}

# Gets the OCID of the first (default) vNIC on the NAT instance
data "oci_core_vnic" "NatInstanceVnic" {
        vnic_id = "${lookup(data.oci_core_vnic_attachments.NatInstanceVnics.vnic_attachments[0],"vnic_id")}"
}

data "oci_core_private_ips" "myPrivateIPs" {
    ip_address = "${data.oci_core_vnic.NatInstanceVnic.private_ip_address}"
    subnet_id = "${oci_core_subnet.MgmtSubnet.id}"
    #vnic_id =  "${data.oci_core_vnic.NatInstanceVnic.id}"
}


resource "oci_core_vnic_attachment" "SecondaryVnicAttachment" {
  instance_id = "${oci_core_instance.NatInstance.id}"
  create_vnic_details {
    subnet_id = "${oci_core_subnet.PrivateSubnet1.id}"
    assign_public_ip = false
    skip_source_dest_check = true
  }
  #count = 1
  provisioner "remote-exec" {
      inline = [
        "sudo iptables -F",
        "sudo iptables -X",
        "sudo /usr/local/bin/secondary_vnic_all_configure.sh -c",
        "sudo firewall-offline-cmd --direct --add-rule ipv4 filter FORWARD 0 -i ens4 -j ACCEPT"
      ]
    connection {
      host = "${oci_core_instance.NatInstance.public_ip}"
      type = "ssh"
      user = "opc"
      private_key = "${file(var.ssh_private_key)}"
      timeout = "3m"
    }
  }

}

# Gets Second VNIC attachment on the NAT instance
data "oci_core_vnic" "NatInstanceSecondVnic" {
    vnic_id = "${oci_core_vnic_attachment.SecondaryVnicAttachment.vnic_id}"
}

data "oci_core_private_ips" "mySecondVnicPrivateIPs" {
    #ip_address = "${data.oci_core_vnic.NatInstanceSecondVnic.private_ip_address}"
    #subnet_id = "${oci_core_subnet.MgmtSubnet.id}"
    #vnic_id =  "${data.oci_core_vnic.NatInstanceSecondVnic.id}"
    vnic_id = "${oci_core_vnic_attachment.SecondaryVnicAttachment.vnic_id}"
}

resource "oci_core_security_list" "PrivateSecurityList" {
    compartment_id = "${var.compartment_ocid}"
    display_name = "PrivateSecurityList"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"
    egress_security_rules = [{
        protocol = "all"
        destination = "0.0.0.0/0"
    }]
    ingress_security_rules = [{
        protocol = "6"
        tcp_options {
            "max" = 22
            "min" = 22
        }
        source = "${var.vcn_cidr}"
    },
    {
        protocol = "all"
        source = "${var.vcn_cidr}"
    }]
}

resource "oci_core_route_table" "PrivateRouteTable1" {
    compartment_id = "${var.compartment_ocid}"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"
    display_name = "PrivateRouteTable1"
}

resource "oci_core_route_table" "PrivateRouteTable2" {
    compartment_id = "${var.compartment_ocid}"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"
    display_name = "PrivateRouteTable2"
    route_rules {
        cidr_block = "0.0.0.0/0"
        network_entity_id = "${lookup(data.oci_core_private_ips.mySecondVnicPrivateIPs.private_ips[0],"id")}"
    }
}

resource "oci_core_subnet" "PrivateSubnet1" {
    availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}"
    cidr_block = "${var.private_subnet1_cidr}"
    display_name = "PrivateSubnet1"
    compartment_id = "${var.compartment_ocid}"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"
    route_table_id = "${oci_core_route_table.PrivateRouteTable1.id}"
    security_list_ids = ["${oci_core_security_list.PrivateSecurityList.id}"]
    dhcp_options_id = "${oci_core_virtual_network.CoreVCN.default_dhcp_options_id}"
    prohibit_public_ip_on_vnic = "true"
}

resource "oci_core_subnet" "PrivateSubnet2" {
    availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}"
    cidr_block = "${var.private_subnet2_cidr}"
    display_name = "PrivateSubnet2"
    compartment_id = "${var.compartment_ocid}"
    vcn_id = "${oci_core_virtual_network.CoreVCN.id}"
    route_table_id = "${oci_core_route_table.PrivateRouteTable2.id}"
    security_list_ids = ["${oci_core_security_list.PrivateSecurityList.id}"]
    dhcp_options_id = "${oci_core_virtual_network.CoreVCN.default_dhcp_options_id}"
    prohibit_public_ip_on_vnic = "true"
}

resource "oci_core_instance" "PrivateInstance" {
    availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}"
    compartment_id = "${var.compartment_ocid}"
    display_name = "PrivateInstance"
    image = "${lookup(data.oci_core_images.OLImageOCID.images[0], "id")}"
    shape = "${var.InstanceShape}"
    create_vnic_details {
      subnet_id = "${oci_core_subnet.PrivateSubnet2.id}"
      assign_public_ip = false
    }
    metadata {
      ssh_authorized_keys = "${var.ssh_public_key}"
    }
    timeouts {
      create = "10m"
    }
}
