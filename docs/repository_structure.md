```text
GoldenPipeline/
    .gitignore
    pipeline-permissions-policy.json
    pytest.ini
    README.md
    requirements-dev.txt
    trust-policy.json

    docs/
        architecture_decisions.md
        queries.md
        repository_structure.md

        diagrams/
            goldenpipeline-architecture.svg
    

    evidence/
        cli/

        screenshots/


    .github/
        workflows/
            ci-cd.yml


    notes/
        design_structure_rationale.md


    packer/
        .pkr.hcl
        cleanup.sh 
        harden_audit.sh
        harden_filesystem.sh
        harden_services.sh
        harden_ssh.sh   
        harden_updates.sh


    terraform/
        .terraform.lock.hcl
        main.tf
        outputs.tf
        terraform.tfvars.example
        variables.tf


        modules/
            ec2/

            iam/

            security_group/

            vpc/


    tests/
        conftest.py
        test_cis_audit.py
        test_cis_filesystem.py
        test_cis_services.py
        test_cis_ssh.py
        test_cis_updates.py

    