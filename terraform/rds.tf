resource "aws_security_group" "rds" {
  name        = "project-bedrock-rds-sg"
  description = "Security group for RDS instances"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    description = "MySQL from EKS"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  
  ingress {
    description = "PostgreSQL from EKS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  
  tags = {
    Name    = "project-bedrock-rds-sg"
    Project = "karatu-2025-capstone"
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "project-bedrock-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  tags = { Project = "karatu-2025-capstone" }
}

resource "aws_db_instance" "mysql" {
  identifier             = "project-bedrock-mysql"
  engine                = "mysql"
  engine_version        = "8.0"
  instance_class        = "db.t3.micro"
  allocated_storage     = 20
  db_name               = "retaildb"
  username              = var.db_username
  password              = var.db_password
  db_subnet_group_name  = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot   = true
  tags = { Project = "karatu-2025-capstone" }
}