#!/bin/bash -ex -o pipefail

SOURCE_REPO_URL="https://github.com/aptos-labs/aptos-core.git"
DESTINATION_REPO_URL="https://github.com/aptos-labs/aptos-framework.git"
COPYBARA_CONFIG="copy.bara.sky.template"
BRANCH_PREFIX="aptos_release_"
EXACT_BRANCH_NAMES=("mainnet")

# Fetch all branches from the source repository
branches=$(git ls-remote --heads $SOURCE_REPO_URL | awk '{print $2}' | sed 's|refs/heads/||')

# Iterate over each branch and run Copybara for branches with the specified prefix or exact name
for branch in $branches; do
  if [[ $branch == $BRANCH_PREFIX* ]] || [[ " ${EXACT_BRANCH_NAMES[@]} " =~ " ${branch} " ]]; then
    echo "Syncing branch: $branch"
    
    # Create a temporary Copybara config with the current branch
    sed "s/PLACEHOLDER_BRANCH/$branch/g" $COPYBARA_CONFIG > copy.bara.sky
    
    # Run Copybara with the temporary config
    copybara migrate copy.bara.sky push_move_libraries_direct --init-history --force
    
    # Clean up the temporary config
    rm copy.bara.sky
  fi
done
