{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.grading-platform;
  composeFile = ../compose.yaml;
  compose = "${pkgs.docker-compose}/bin/docker-compose";
in
{
  options.services.grading-platform = {
    enable = lib.mkEnableOption "Autolab and Tango grading platform";

    hostname = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "grading.dos.cit.tum.de";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = "Root-readable environment file containing platform secrets and image references.";
    };

    kubernetesApi = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "https://astrid.dos.cit.tum.de:6443";
    };

    kubernetesNamespace = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "grading";
    };

    tokenSecret = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "tango-kubernetes-backend-token";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.k3s.enable && config.services.k3s.role == "server";
        message = "The grading platform must run on the k3s server.";
      }
    ];

    virtualisation.docker.enable = true;

    systemd.services.grading-platform-kubeconfig = {
      description = "Generate Tango's namespaced Kubernetes kubeconfig";
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      before = [ "grading-platform.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        config.services.k3s.package
        pkgs.coreutils
      ];
      script = ''
        set -eu
        install -d -m 0700 /run/grading

        token=""
        attempts=0
        while [ -z "$token" ] && [ "$attempts" -lt 60 ]; do
          token="$(k3s kubectl -n grading-system get secret ${cfg.tokenSecret} -o jsonpath='{.data.token}' 2>/dev/null || true)"
          attempts=$((attempts + 1))
          if [ -z "$token" ]; then
            sleep 1
          fi
        done
        if [ -z "$token" ]; then
          echo "ServiceAccount token was not populated" >&2
          exit 1
        fi

        ca="$(base64 -w0 /var/lib/rancher/k3s/server/tls/server-ca.crt)"
        token="$(printf '%s' "$token" | base64 -d)"
        umask 077
        {
          printf '%s\n' 'apiVersion: v1' 'kind: Config'
          printf '%s\n' 'clusters:' '  - name: grading'
          printf '    cluster:\n      server: %s\n      certificate-authority-data: %s\n' '${cfg.kubernetesApi}' "$ca"
          printf '%s\n' 'users:' '  - name: tango' '    user:'
          printf '      token: %s\n' "$token"
          printf '%s\n' 'contexts:' '  - name: grading' '    context:'
          printf '      cluster: grading\n      namespace: %s\n      user: tango\n' '${cfg.kubernetesNamespace}'
          printf '%s\n' 'current-context: grading'
        } > /run/grading/tango.kubeconfig
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    systemd.services.grading-platform = {
      description = "Autolab and Tango grading platform";
      after = [
        "docker.service"
        "grading-platform-kubeconfig.service"
        "network-online.target"
      ];
      requires = [
        "docker.service"
        "grading-platform-kubeconfig.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment.COMPOSE_PROJECT_NAME = "grading-platform";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${compose} --env-file ${cfg.environmentFile} -f ${composeFile} up --remove-orphans";
        ExecStop = "${compose} --env-file ${cfg.environmentFile} -f ${composeFile} down";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 0;
        TimeoutStopSec = 120;
      };
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts.${cfg.hostname} = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;
        };
      };
    };

    security.acme.acceptTerms = true;
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
