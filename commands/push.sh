#!/bin/bash
set -ueo pipefail

push_retries="$(plugin_read_config PUSH_RETRIES "0")"

if [[ "${BUILDKITE_PLUGIN_DOCKER_COMPOSE_COLLAPSE_LOGS:-false}" = "true" ]]; then
  group_type="---"
else
  group_type="+++"
fi

# Targets for pushing come in a variety of forms:

# service <- just a service name
# service:image <- a service name and a specific image name to use
# service:image:tag <- a service name and a specific image and tag to use

# A push figures out the source image from either:
# 1. An image declaration in the docker-compose config for that service
# 2. The default projectname_service image format that docker-compose uses

pulled_services=("")

# Then we figure out what to push, and where
for line in $(plugin_read_list PUSH) ; do
  IFS=':' read -r -a tokens <<< "$line"
  service_name=${tokens[0]}
  service_image=$(compose_image_for_service "$service_name")

  if docker_image_exists "${service_image}"; then
    echo "~~~ :docker: Using service image ${service_image} from Docker Compose config"
  elif prebuilt_image="$(get_prebuilt_image "$service_name")"; then
    echo "~~~ :docker: Using pre-built image ${prebuilt_image}"

    # Only pull it down once
    if ! in_array "${service_name}" "${pulled_services[@]}" ; then
      echo "~~~ :docker: Pulling pre-built service ${service_name}" >&2;
      retry "$push_retries" plugin_prompt_and_run docker pull "$prebuilt_image"
      pulled_services+=("${service_name}")
    fi

    service_image="${prebuilt_image}"
  else
    echo "+++ 🚨 No prebuilt-image nor service image found for service to push"
    exit 1
  fi

  # push: "service-name"
  if [[ ${#tokens[@]} -eq 1 ]] ; then
    echo "~~~ :docker: Pushing images for ${service_name}" >&2;
    retry "$push_retries" run_docker_compose push "${service_name}"
    set_prebuilt_image "${service_name}" "${service_image}"
  # push: "service-name:repo:tag"
  else
    target_image="$(IFS=:; echo "${tokens[*]:1}")"
    echo "${group_type} :docker: Pushing image $target_image" >&2;
    plugin_prompt_and_run docker tag "$service_image" "$target_image"
    retry "$push_retries" plugin_prompt_and_run docker push "$target_image"
    set_prebuilt_image "${service_name}" "${target_image}"
  fi
done

# single image build
for service_alias in $(plugin_read_list BUILD_ALIAS) ; do
  if [ -n "${BUILDKITE_PLUGIN_DOCKER_COMPOSE_BUILD}" ]; then
    echo "+++ 🚨 You can not use build-alias if you are not building a single service"
    exit 1
  fi

  set_prebuilt_image "$service_alias" "${target_image}"
done