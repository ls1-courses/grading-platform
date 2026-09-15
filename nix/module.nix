{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.grading-platform;
  tangoComposeFile = ../compose.tango.yaml;
  webComposeFile = ../compose.web.yaml;
  playbook = ../ansible/grading-web.yml;
  compose = "${pkgs.docker-compose}/bin/docker-compose";
in
{
  options.services.grading-platform = {
    enable = lib.mkEnableOption "Tango and automatic provisioning of the Autolab web VM";

    tangoEnvironmentFile = lib.mkOption {
      type = lib.types.path;
      description = "Root-readable environment file for the local Tango stack.";
    };

    webEnvironmentFile = lib.mkOption {
      type = lib.types.path;
      description = "Root-readable environment file copied to the Autolab VM.";
    };

    deployKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Private SSH key used to provision the Autolab VM as deploy.";
    };

    webHost = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "grading.dos.cit.tum.de";
    };

    webAddress = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "172.24.89.4";
      description = "Source address allowed to reach the Tango HTTPS endpoint.";
    };

    webHostPublicKey = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHHP3OZd4lhDqRwuUx+bH5AwMW8x6VB8VQRiBsDgUM+w";
    };

    tangoHostname = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "astrid.dos.cit.tum.de";
    };

    tangoTlsCertificateFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/etc/pira-client/live/host:f:astrid.dos.cit.tum.de.fullchain.pem";
      description = "Externally managed PIRA full certificate chain on Astrid.";
    };

    tangoTlsCertificateKeyFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/etc/pira-client/live/host:f:astrid.dos.cit.tum.de.privkey.pem";
      description = "Externally managed PIRA private key on Astrid.";
    };

    webTlsCertificateFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/etc/pira-client/live/host:f:grading.dos.cit.tum.de.fullchain.pem";
      description = "Externally managed PIRA full certificate chain on the web VM.";
    };

    webTlsCertificateKeyFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/etc/pira-client/live/host:f:grading.dos.cit.tum.de.privkey.pem";
      description = "Externally managed PIRA private key on the web VM.";
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
        message = "The Tango grading platform must run on the k3s server.";
      }
    ];

    virtualisation.docker.enable = true;

    programs.ssh.knownHosts.${cfg.webHost} = {
      hostNames = [ cfg.webHost ];
      publicKey = cfg.webHostPublicKey;
    };

    systemd.services.grading-platform-kubeconfig = {
      description = "Generate Tango's namespaced Kubernetes kubeconfig";
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      before = [ "grading-tango.service" ];
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

    systemd.services.grading-tango = {
      description = "Tango Kubernetes grading controller";
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
      environment.COMPOSE_PROJECT_NAME = "grading-tango";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${compose} --env-file ${cfg.tangoEnvironmentFile} -f ${tangoComposeFile} up --remove-orphans";
        ExecStop = "${compose} --env-file ${cfg.tangoEnvironmentFile} -f ${tangoComposeFile} down";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 0;
        TimeoutStopSec = 120;
      };
    };

    systemd.services.grading-web-provision = {
      description = "Provision the Autolab Ubuntu VM";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.ansible
        pkgs.openssh
      ];
      environment = {
        ANSIBLE_HOST_KEY_CHECKING = "True";
        ANSIBLE_NOCOLOR = "True";
      };
      script = ''
        set -eu
        ansible-playbook \
          --inventory '${cfg.webHost},' \
          --user deploy \
          --private-key "$CREDENTIALS_DIRECTORY/deploy-key" \
          --extra-vars "web_compose_file=${webComposeFile}" \
          --extra-vars "web_environment_file=$CREDENTIALS_DIRECTORY/web-environment" \
          --extra-vars "tls_certificate_file=${cfg.webTlsCertificateFile}" \
          --extra-vars "tls_certificate_key_file=${cfg.webTlsCertificateKeyFile}" \
          ${playbook}
      '';
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [
          "deploy-key:${cfg.deployKeyFile}"
          "web-environment:${cfg.webEnvironmentFile}"
        ];
      };
    };

    systemd.timers.grading-web-provision = {
      description = "Regularly reconcile the Autolab Ubuntu VM";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "1d";
        RandomizedDelaySec = "15min";
        Persistent = true;
      };
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = {
        ${cfg.tangoHostname} = {
          onlySSL = true;
          sslCertificate = cfg.tangoTlsCertificateFile;
          sslCertificateKey = cfg.tangoTlsCertificateKeyFile;
          locations."/".return = "404";
        };
        grading-tango-api = {
          serverName = cfg.tangoHostname;
          onlySSL = true;
          sslCertificate = cfg.tangoTlsCertificateFile;
          sslCertificateKey = cfg.tangoTlsCertificateKeyFile;
          listen = [
            {
              addr = "0.0.0.0";
              port = 3000;
              ssl = true;
            }
            {
              addr = "[::]";
              port = 3000;
              ssl = true;
            }
          ];
          locations."/" = {
            proxyPass = "http://127.0.0.1:3001";
            extraConfig = ''
              allow ${cfg.webAddress};
              deny all;
            '';
          };
        };
      };
    };

  };
}
