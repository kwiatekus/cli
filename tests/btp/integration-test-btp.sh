#!/bin/bash

echo "Running kyma integration tests uing connected managed kyma runtime"

# -------------------------------------------------------------------------------------
echo "Step1: Generating temporary access for new service account"

../../bin/kyma alpha kubeconfig generate --clusterrole cluster-admin --serviceaccount test-sa --output /tmp/kubeconfig.yaml --time 2h

export KUBECONFIG="/tmp/kubeconfig.yaml"
if [[ $(kubectl config view --minify --raw | yq '.users[0].name') != 'test-sa' ]]; then
    exit 1
fi
echo "Running test in user context of: $(kubectl config view --minify --raw | yq '.users[0].name')"
# -------------------------------------------------------------------------------------
echo "Step2: List modules"
../../bin/kyma alpha module list

# -------------------------------------------------------------------------------------
echo "Step3: Connecting to a service manager from remote BTP subaccount"

# fetch SM binding (cred.json) via terraform  
terraform -chdir=tf init
terraform -chdir=tf apply --auto-approve
# terraform -chdir=tf apply --auto-approve -var-file=.tfvars

# https://help.sap.com/docs/btp/sap-business-technology-platform/namespace-level-mapping?locale=en-US
( cd tf ; curl https://raw.githubusercontent.com/kyma-project/btp-manager/main/hack/create-secret-file.sh | bash -s operator remote-service-manager-credentials )
kubectl create -f tf/btp-access-credentials-secret.yaml || true

# -------------------------------------------------------------------------------------
echo "Step4: Create service instance reference to a shared object-store service instance"

echo "Waiting for CRD btp operator"
while ! kubectl get crd btpoperators.operator.kyma-project.io; do echo "Waiting for CRD btp operator..."; sleep 1; done
kubectl wait --for condition=established crd/btpoperators.operator.kyma-project.io
while ! kubectl get btpoperators.operator.kyma-project.io btpoperator --namespace kyma-system; do echo "Waiting for btpoperator..."; sleep 1; done
kubectl wait --for condition=Ready btpoperators.operator.kyma-project.io/btpoperator -n kyma-system --timeout=180s


# TODO - change after btp operator commands are extracted as btp module cli extension
../../bin/kyma@v3 alpha reference-instance \
    --btp-secret-name remote-service-manager-credentials \
    --namespace kyma-system \
    --offering-name objectstore \
    --plan-selector standard \
    --reference-name object-store-reference
kubectl apply -n kyma-system -f ./k8s-resources/object-store-binding.yaml

while ! kubectl get secret object-store-reference-binding --namespace kyma-system; do echo "Waiting for object-store-reference-binding secret..."; sleep 5; done

# -------------------------------------------------------------------------------------
# Enable Docker Registry
echo "Step5: Enable Docker Registry from experimental channel (with persistent BTP based storage)"
../../bin/kyma alpha module add docker-registry --channel experimental --cr-path k8s-resources/exposed-docker-registry.yaml

echo "..waiting for docker registry"
kubectl wait --for condition=Installed dockerregistries.operator.kyma-project.io/custom-dr -n kyma-system --timeout=360s

dr_external_url=$(../../bin/kyma@v3 alpha registry config --externalurl)

# TODO new cli command, for example
# dr_internal_pull_url=$(../../bin/kyma@v3 alpha registry config --internalurl)
dr_internal_pull_url=$(kubectl get dockerregistries.operator.kyma-project.io -n kyma-system custom-dr -ojsonpath={.status.internalAccess.pullAddress})

../../bin/kyma@v3 alpha registry config --output config.json

echo "Docker Registry enabled (URLs: $dr_external_url, $dr_internal_pull_url)"
echo "config.json for docker CLI access generated"
# -------------------------------------------------------------------------------------
echo "Step6: Map SAP Hana DB instance with Kyma runtime"

../../bin/kyma@v3 alpha hana map --credentials-path tf/hana-admin-creds.json

# -------------------------------------------------------------------------------------
echo "Step7: Pack & push hdi-deploy image"

# build hdi-deploy via pack and push it via docker CLI (external url)
pack build hdi-deploy:latest -p sample-http-db-nodejs/hdi-deploy -B paketobuildpacks/builder:base
docker tag hdi-deploy:latest $dr_external_url/hdi-deploy:latest
docker --config . push $dr_external_url/hdi-deploy:latest

# -------------------------------------------------------------------------------------
echo "Step8: Deploy hdi-deploy (hdi instance & binding, run db initialisation)"

echo "Initialising db binding..."
kubectl set image -f ./k8s-resources/db/books-hdi-initjob-template.yaml bookstore-db=$dr_internal_pull_url/hdi-deploy:latest --local -o yaml > ./k8s-resources/db/books-hdi-initjob.yaml
kubectl apply -k ./k8s-resources/db
echo "Waiting for hana-init-job to complete..."
kubectl wait --for condition=Complete jobs/hana-hdi-initjob --timeout=360s 
echo "Bookstore db initialised" 

# -------------------------------------------------------------------------------------
echo "Step9: Pushing bookstore app"

# build hdi-deploy via pack and push it via docker CLI (external url)
pack build bookstore:latest -p sample-http-db-nodejs/bookstore -B paketobuildpacks/builder:base
docker tag bookstore:latest $dr_external_url/bookstore:latest
docker --config . push $dr_external_url/bookstore:latest

# TODO check why this fails on GH action with 
# Importing bookstore:2025-03-13_16-06-26
# Error:
#   failed to import image to in-cluster registry

# Error Details:
#   failed to push image to the in-cluster registry: PUT https://localhost:32137/v2/bookstore/blobs/uploads/c0ae3d32-c861-4ed5-a796-43bf9434b954?_state=REDACTED&digest=sha256%3Acb4197092ed16fbdd56eafda1c0995d527ca3a0621d3b1787a1376e8478d751c: BLOB_UPLOAD_UNKNOWN: blob upload unknown to registry; map[]


#../../bin/kyma@v3 alpha app push --name bookstore --expose --container-port 3000 --mount-secret hana-hdi-binding --code-path sample-http-db-nodejs/bookstore

../../bin/kyma@v3 alpha app push --name bookstore --expose --container-port 3000 --mount-secret hana-hdi-binding --image $dr_internal_pull_url/bookstore:latest

#TODO replace with --image-pull-secret after https://github.com/kyma-project/cli/issues/2411
kubectl patch deployment bookstore --type='merge' -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"dockerregistry-config"}]}}}}'
kubectl wait --for condition=Available deployment bookstore --timeout=60s
kubectl wait --for='jsonpath={.status.state}=Ready' apirules.gateway.kyma-project.io/bookstore
# -------------------------------------------------------------------------------------
echo "Step10: Verify bookstore app"
sleep 5
response=$(curl https://bookstore.$DOMAIN/v1/books)
echo "HTTP response from sample app: $response"

if [[ $response != '[{"id":1,"title":"Dune","author":"Frank Herbert"},{"id":2,"title":"Pippi Goes on Board","author":"Astrid Lindgren"}]' ]]; then
    exit 1
fi


exit 0