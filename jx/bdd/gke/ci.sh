#!/usr/bin/env bash
set -e
set -x

echo PATH=$PATH
echo HOME=$HOME

export PATH=$PATH:/usr/local/bin

# setup environment
KUBECONFIG="/tmp/jxhome/config"

#export XDG_CONFIG_HOME="/builder/home/.config"
mkdir -p /home/.config
cp -r /home/.config /builder/home/.config

jx version
jx help

export JX3_HOME=/home/.jx3
jx admin --help
jx secret --help


export GIT_USERNAME="jenkins-x-labs-bot"
export GIT_USER_EMAIL="jenkins-x@googlegroups.com"
export GH_OWNER="cb-kubecd"
export GIT_TOKEN="${GH_ACCESS_TOKEN//[[:space:]]}"

export PROJECT_ID=jenkins-x-labs-bdd
export CREATED_TIME=$(date '+%a-%b-%d-%Y-%H-%M-%S')
export CLUSTER_NAME="${BRANCH_NAME,,}-$BUILD_NUMBER-bdd-gke"
export ZONE=europe-west1-c
export LABELS="branch=${BRANCH_NAME,,},cluster=bdd-gke,create-time=${CREATED_TIME,,}"

# lets setup git
git config --global --add user.name JenkinsXBot
git config --global --add user.email jenkins-x@googlegroups.com

echo "running the BDD test with JX_HOME = $JX_HOME"

mkdir -p $XDG_CONFIG_HOME/git
# replace the credentials file with a single user entry
echo "https://${GIT_USERNAME//[[:space:]]}:${GIT_TOKEN}@github.com" > $XDG_CONFIG_HOME/git/credentials

echo "using git credentials: $XDG_CONFIG_HOME/git/credentials"
ls -al $XDG_CONFIG_HOME/git/credentials

echo "creating cluster $CLUSTER_NAME in project $PROJECT_ID with labels $LABELS"

echo "lets get the PR head clone URL"
export PR_SOURCE_URL=$(jx gitops pr get --git-token=$GH_ACCESS_TOKEN --head-url)

echo "using the version stream url $PR_SOURCE_URL ref: $PULL_PULL_SHA"

# the gitops repository template to use
export GITOPS_TEMPLATE_PROJECT="jx3-gitops-repositories/jx3-gke-gcloud-vault"

export GITOPS_TEMPLATE_URL="https://github.com/${GITOPS_TEMPLATE_PROJECT}.git"

# lets find the current template  version
export GITOPS_TEMPLATE_VERSION=$(grep  'version: ' /workspace/source/git/github.com/$GITOPS_TEMPLATE_PROJECT.yml | awk '{ print $2}')

echo "using GitOps template: $GITOPS_TEMPLATE_URL version: $GITOPS_TEMPLATE_VERSION"

# TODO support versioning?
#git clone -b v${GITOPS_TEMPLATE_VERSION} $GITOPS_TEMPLATE_URL

# create the boot git repository to mimic creating the git repository via the github create repository wizard
jx admin create -b --initial-git-url $GITOPS_TEMPLATE_URL --env dev --provider=gke --version-stream-ref=$PULL_PULL_SHA --version-stream-url=${PR_SOURCE_URL//[[:space:]]} --env-git-owner=$GH_OWNER --repo env-$CLUSTER_NAME-dev --no-operator

git clone https://${GIT_USERNAME//[[:space:]]}:${GIT_TOKEN}@github.com/${GH_OWNER}/env-${CLUSTER_NAME}-dev.git
cd env-${CLUSTER_NAME}-dev


# lets create the cluster
./bin/create_cluster.sh

# lets add / commit any cloud resource specific changes
git add *
git commit -a -m "chore: cluster changes"
git push

#gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE --project $PROJECT_ID

# now lets install the operator
# --username is found from $GIT_USERNAME or git clone URL
# --token is found from $GIT_TOKEN or git clone URL
#jx admin operator --username $GIT_USERNAME --token $GH_ACCESS_TOKEN
jx admin operator

# lets modify the git repo stuff - eventually we can remove this?
# wait for vault to get setup
jx secret vault wait -d 30m

jx secret vault portforward &

sleep 30

# import secrets...
echo "secret:
  jx:
    adminUser:
      password: $JENKINS_PASSWORD
      username: admin
    docker:
      password: dummy
      username: admin
    mavenSettings:
      settingsXml: dummy
      securityXml: dummy
    pipelineUser:
      username: $GIT_USERNAME
      token: $GH_ACCESS_TOKEN
      email: $GIT_USER_EMAIL
  lighthouse:
    hmac:
      token: 2efa226914ae6e81d062e9566646bd54bb1c0cc23" > /tmp/secrets.yaml

jx secret import -f /tmp/secrets.yaml

sleep 90

jx secret verify

jx ns jx

# diagnostic commands to test the image's kubectl
kubectl version

# for some reason we need to use the full name once for the second command to work!
kubectl get environments
kubectl get env
kubectl get env dev -oyaml

# lets wait for things to be installed correctly
make verify-install

kubectl get cm config -oyaml

export JX_DISABLE_DELETE_APP="true"
export JX_DISABLE_DELETE_REPO="true"

export GIT_ORGANISATION="$GH_OWNER"


# lets turn off color output
export TERM=dumb

echo "about to run the bdd tests...."

# run the BDD tests
bddjx -ginkgo.focus=golang -test.v
#bddjx -ginkgo.focus=javascript -test.v


echo "completed the bdd tests"

echo cleaning up cloud resources
curl https://raw.githubusercontent.com/jenkins-x-labs/cloud-resources/v$CLOUD_RESOURCES_VERSION/gcloud/cleanup-cloud-resurces.sh | bash
gcloud container clusters delete $CLUSTER_NAME --zone $ZONE --quiet
