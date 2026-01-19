# AWS provider configuration
# This is required to manage AWS resources. The region is dynamically set via a variable.
provider "aws" {
  region = var.cloud_region  
  # Default tags to apply to all resources
  default_tags {
    tags = {
      owner_email       = var.email
    }
  }
}



# default security group in the desired VPC
data "aws_vpc" "default" {
  default = true
}

resource "random_id" "env_display_id" {
    byte_length = 4
}

resource "aws_security_group" "db_security_group" {
  name   = "db_sg_${random_id.env_display_id.hex}"
  vpc_id = data.aws_vpc.default.id
}

#  rule to the default security group
resource "aws_security_group_rule" "allow_inbound_postgres" {
  type              = "ingress"
  from_port         = 5432              
  to_port           = 5432              
  protocol          = "tcp"
  security_group_id = aws_security_group.db_security_group.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "allow_outbound_postgres" {
  type              = "egress"
  from_port         = 5432              
  to_port           = 5432              
  protocol          = "tcp"
  security_group_id = aws_security_group.db_security_group.id
  cidr_blocks       = ["0.0.0.0/0"]
}


resource "aws_db_instance" "postgres_db" {
  allocated_storage    = 30
  engine             = "postgres"
  engine_version     = "16.8"
  instance_class     = "db.t3.medium"
  identifier         = "${var.use_prefix}health-${random_id.env_display_id.hex}"
  db_name = "patientdb"
  username           = var.db_username
  password           = var.db_password
  publicly_accessible = true
  parameter_group_name = aws_db_parameter_group.pg_parameter_group.name
  vpc_security_group_ids = [aws_security_group.db_security_group.id]
  apply_immediately    = true
  skip_final_snapshot = true
}


resource "aws_db_parameter_group" "pg_parameter_group" {
  name   = "${var.use_prefix}rds-pg-debezium-${random_id.env_display_id.hex}"
  family = "postgres16"

  parameter {
    apply_method = "pending-reboot"
    name  = "rds.logical_replication"
    value = 1
  }
}

# Create the database tables using a local-exec provisioner
resource "null_resource" "create_tables" {
  depends_on = [aws_db_instance.postgres_db]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
      PGPASSWORD=${var.db_password} psql \
        -h ${aws_db_instance.postgres_db.address} \
        -p ${aws_db_instance.postgres_db.port} \
        -U ${aws_db_instance.postgres_db.username} \
        -d ${aws_db_instance.postgres_db.db_name} \
        -c "
      CREATE TABLE IF NOT EXISTS patient (
          patient_id INT PRIMARY KEY,
          name VARCHAR(255) NOT NULL,
          age INT NOT NULL
      );"
      PGPASSWORD=${var.db_password} psql \
        -h ${aws_db_instance.postgres_db.address} \
        -p ${aws_db_instance.postgres_db.port} \
        -U ${aws_db_instance.postgres_db.username} \
        -d ${aws_db_instance.postgres_db.db_name} \
        -c "
        INSERT INTO patient (patient_id, name, age) VALUES
        (1, 'John Doe',      45),
        (2, 'Jane Smith',    32),
        (3, 'Michael Brown', 50),
        (4, 'Emily Davis',   88),
        (5, 'Daniel Wilson', 60),
        (6, 'Sarah Johnson', 41),
        (7, 'David Miller',  37),
        (8, 'Laura Garcia',  69),
        (9, 'Robert Miller', 55),
        (10, 'Anna Lopez', 34)
        ON CONFLICT (patient_id) DO NOTHING;"
    EOT
  }
}

output "resource-ids" {

  value = <<-EOT

----------------------------
   DATABASE CONFIGURATION
------------------------------
  RDS Endpoint: ${aws_db_instance.postgres_db.endpoint}
  RDS DB Name: patientdb
  RDS username: ${var.db_username}
  RDS password: ${var.db_password}
  EOT

  sensitive = false
}

