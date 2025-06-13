#!/bin/bash
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'

# Function to generate a random string of 5 characters
generate_random_string() {
  local random_string=$(LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 5 ; echo '')
  echo "${random_string}-$(LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 5 ; echo '')"
}

# Function to generate a project ID
generate_project_id() {
  local random_suffix=$(generate_random_string)
  echo "$random_suffix"
}

# Function to generate a project name
generate_project_name() {
  random_numbers=$(generate_random_numbers)
  echo "Project-$random_numbers"
}

# Function to generate a random string of 5 numbers
generate_random_numbers() {
  local random_numbers=$(shuf -i 0-99999 -n 1)
  printf "%05d" "$random_numbers"
}

# Function to generate a random number between 1000 and 9999
generate_random_number() {
  echo $((1000 + RANDOM % 9000))
}

# Function to generate a valid instance name
generate_valid_instance_name() {
  local random_number=$(generate_random_number)
  echo "vm-${random_number}"
}

# Get hash value from command-line argument, default to empty if not provided
hash_value="${1:-}"

# Check if hash_value is empty
if [ -z "$hash_value" ]; then
    echo -e "${RED}Error: No hash value provided. Usage: $0 <hash_value>${NC}"
    exit 1
fi

startup_script_url="https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/gcp/install-edge.sh"
# List of regions where virtual machines will be created
zones=(
  "us-east4-a"
  "us-east1-b"
  "us-east5-a"
  "us-east4-b"
  "us-east1-c"
  "us-east5-b"
)

# Check if an organization exists
organization_id=$(gcloud organizations list --format="value(ID)" 2>/dev/null)
echo -e "${BLUE}Organization ID: $organization_id${NC}"

# Get the billing account ID
billing_account_id=$(gcloud beta billing accounts list --format="value(name)" | head -n 1)
echo -e "${BLUE}Billing Account ID: $billing_account_id${NC}"

# Function to ensure the required number of projects exist
ensure_n_projects() {
  desired_projects=2
  if [ -n "$organization_id" ]; then
    current_projects=$(gcloud projects list --format="value(projectId)" --filter="parent.id=$organization_id" 2>/dev/null | wc -l)
  else
    current_projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null | wc -l)
  fi

  echo -e "${BLUE}Current Projects: $current_projects${NC}"

  if [ "$current_projects" -lt "$desired_projects" ]; then
    projects_to_create=$((desired_projects - current_projects))
    echo -e "${ORANGE}Creating $projects_to_create project(s) to meet requirement of $desired_projects...${NC}"

    for ((i = 0; i < projects_to_create; i++)); do
      local project_id=$(generate_project_id)
      local project_name=$(generate_project_name)

      if [ -n "$organization_id" ]; then
        gcloud projects create "$project_id" --name="$project_name" --organization="$organization_id"
      else
        gcloud projects create "$project_id" --name="$project_name"
      fi
      sleep 8
      gcloud alpha billing projects link "$project_id" --billing-account="$billing_account_id"
      gcloud config set project "$project_id"
      echo -e "${BLUE}Created project '$project_name' (ID: $project_id)${NC}"
      sleep 2
    done
  else
    echo -e "${BLUE}Sufficient projects ($current_projects) already exist${NC}"
  fi
}

# Function to create a firewall rule for a project
create_firewall_rule() {
    local project_id=$1
    gcloud compute --project="$project_id" firewall-rules create public-network \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=all \
        --source-ranges=0.0.0.0/0
    echo -e "${BLUE}Firewall rule 'public-network' created for project $project_id, allowing all protocols and ports${NC}"
}

# Function to re-enable compute API and create firewall rules for projects
re_enable_compute_projects() {
    local projects=$(gcloud projects list --format="value(projectId)")
    if [ -z "$projects" ]; then
        echo -e "${RED}Error: No projects found. Please re-run the script.${NC}"
        exit 1
    fi
    echo -e "${BLUE}Processing projects: $projects${NC}"
    for project_ide in $projects; do
        echo -e "${ORANGE}Enabling Compute Engine API for project $project_ide...${NC}"
        gcloud services enable compute.googleapis.com --project "$project_ide"
        create_firewall_rule "$project_ide"
        echo -e "${BLUE}Compute Engine API enabled for project $project_ide${NC}"
    done
}

# Function to check and wait for a service to be enabled
check_service_enablement() {
    local project_id="$1"
    local service_name="compute.googleapis.com"
    echo -e "${ORANGE}Verifying $service_name status for project $project_id...${NC}"

    while true; do
        service_status=$(gcloud services list --enabled --project "$project_id" --filter="NAME:$service_name" --format="value(NAME)")
        if [[ "$service_status" == "$service_name" ]]; then
            echo -e "${BLUE}$service_name is enabled for project $project_id${NC}"
            break
        else
            echo -e "${RED}$service_name is not enabled for project $project_id. Retrying in 5 seconds...${NC}"
            sleep 5
        fi
    done
}

# Function to run check_service_enablement for all projects
run_enable_project_apicomputer() {
   local projects=$(gcloud projects list --format="value(projectId)")
   for project_id in $projects; do
    check_service_enablement "$project_id"
   done
}

# Function to create virtual machines
create_vms() {
    local projects=$(gcloud projects list --format="value(projectId)")
    for project_id in $projects; do
        echo -e "${ORANGE}Creating VMs for project $project_id...${NC}"
        gcloud config set project "$project_id"
        service_account_email=$(gcloud iam service-accounts list --project="$project_id" --format="value(email)" | head -n 1)
        if [ -z "$service_account_email" ]; then
            echo -e "${RED}Error: No service account found in project $project_id${NC}"
            continue
        fi
        for zone in "${zones[@]}"; do
            instance_name=$(generate_valid_instance_name)
            gcloud compute instances create "$instance_name" \
                --project="$project_id" \
                --zone="$zone" \
                --machine-type=t2d-standard-1 \
                --network-interface=network-tier=PREMIUM,nic-type=GVNIC,stack-type=IPV4_ONLY,subnet=default \
                --maintenance-policy=MIGRATE \
                --provisioning-model=STANDARD \
                --service-account="$service_account_email" \
                --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
                --create-disk=auto-delete=yes,boot=yes,device-name="$instance_name",image=projects/ubuntu-os-cloud/global/images/ubuntu-2204-jammy-v20240607,mode=rw,size=68,type=projects/"$project_id"/zones/"$zone"/diskTypes/pd-balanced \
                --no-shielded-secure-boot \
                --shielded-vtpm \
                --shielded-integrity-monitoring \
                --labels=goog-ec-src=vm_add-gcloud \
                --metadata=startup-script="wget $startup_script_url -4O install-edge.sh || curl $startup_script_url -Lo install-edge.sh && bash install-edge.sh $hash_value" \
                --reservation-affinity=any
            if [ $? -eq 0 ]; then
                echo -e "${BLUE}Instance $instance_name created in project $project_id, zone $zone${NC}"
            else
                echo -e "${RED}Failed to create instance $instance_name in project $project_id, zone $zone${NC}"
            fi
        done
    done
}

# Function to list all server IPs
list_of_servers() {
    local projectsss=($(gcloud projects list --format="value(projectId)"))
    all_ips=()
    for projects_id in "${projectsss[@]}"; do
        echo -e "${ORANGE}Retrieving VM IPs for project $projects_id...${NC}"
        gcloud config set project "$projects_id"
        ips=($(gcloud compute instances list --format="value(EXTERNAL_IP)" --project="$projects_id"))
        all_ips+=("${ips[@]}")
    done
    echo -e "${BLUE}Public IP Addresses:${NC}"
    for ip in "${all_ips[@]}"; do
        echo -e "${BLUE}  $ip${NC}"
    done
}

# Function to initialize and remove projects
init_rm() {
    billing_accounts=$(gcloud beta billing accounts list --format="value(name)")
    echo -e "${ORANGE}Disabling billing for all projects...${NC}"
    for account in $billing_accounts; do
        for project in $(gcloud beta billing projects list --billing-account="$account" --format="value(projectId)"); do
            echo -e "${ORANGE}Disabling billing for project $project...${NC}"
            gcloud beta billing projects unlink "$project"
        done
    done
    echo -e "${BLUE}Billing disabled for all projects${NC}"
    echo -e "${ORANGE}Deleting all projects...${NC}"
    for projectin in $(gcloud projects list --format="value(projectId)"); do
        echo -e "${ORANGE}Deleting project $projectin...${NC}"
        gcloud projects delete "$projectin" --quiet
    done
    echo -e "${BLUE}All projects deleted${NC}"
}

# Function to wait for all projects to be deleted
wait_for_projects_deleted() {
  local current_projects
  while true; do
    current_projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null)
    if [ -z "$current_projects" ] || [ "$(echo "$current_projects" | wc -l)" -eq 0 ]; then
      echo -e "${BLUE}All projects successfully deleted${NC}"
      break
    else
      echo -e "${ORANGE}Waiting for deletion of $(echo "$current_projects" | wc -l) project(s)...${NC}"
      sleep 7
    fi
  done
}

# Function to wait for the required number of projects to be created
wait_for_projects_created() {
  local desired_projects=2
  local current_projects=0
  while [ "$current_projects" -lt "$desired_projects" ]; do
    if [ -n "$organization_id" ]; then
      current_projects=$(gcloud projects list --format="value(projectId)" --filter="parent.id=$organization_id" 2>/dev/null | wc -l)
    else
      current_projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null | wc -l)
    fi
    if [ "$current_projects" -ge "$desired_projects" ]; then
      echo -e "${BLUE}$current_projects projects successfully created${NC}"
      break
    else
      echo -e "${ORANGE}Waiting for creation of $((desired_projects - current_projects)) project(s)...${NC}"
      sleep 5
    fi
  done
}

# Main function to orchestrate the process
main() {
    echo -e "${YELLOW}=== Titan Network VM Creation Script ===${NC}"
    echo -e "${BLUE}Initializing VM setup process...${NC}"
    echo -e "${ORANGE}Clearing existing projects...${NC}"
    init_rm
    wait_for_projects_deleted
    ensure_n_projects
    wait_for_projects_created
    echo -e "${BLUE}Project setup completed${NC}"
    re_enable_compute_projects
    run_enable_project_apicomputer
    echo -e "${ORANGE}Creating virtual machines...${NC}"
    create_vms
    echo -e "${ORANGE}Retrieving VM IP addresses...${NC}"
    list_of_servers
    echo -e "${YELLOW}=== VM Setup Completed ===${NC}"
}
main
