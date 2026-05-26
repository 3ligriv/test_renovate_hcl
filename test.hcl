job "mailserver" {
    group "servers" {
        volume "mailserver-config" {
            type = "host"
            source = "mailserver-config"
            access_mode = "single-node-single-writer"
            attachment_mode = "file-system"
        }

        volume "mailserver-data" {
            type = "host"
            source = "mailserver-data"
            access_mode = "single-node-single-writer"
            attachment_mode = "file-system"
        }

        ephemeral_disk {
            migrate = true
            size = 1024
        }

        network {
            port "smtp" {
                static = "25"
            }

            port "smtps" {
                static = "465"
            }

            port "imaps" {
                static = "993"
            }
        }

        service {
            name = "smtps"
            port = "smtps"
            provider = "nomad"

            // Checks appear as ERRORs, inside the container
            /*check {
                name = "smtps_probe"
                type = "tcp"
                interval = "1m"
                timeout = "2s"
            }*/
        }

        task "docker-mailserver" {
            resources {
                cpu = 1000
                memory = 2000
                memory_max = 4000
            }

            driver = "docker"
            config {
                image = "mailserver/docker-mailserver:15"
                hostname = "mail.lantey.org"
                ports = ["smtp","smtps","imaps"]

                mount {
                    type = "bind"
                    target = "/etc/localtime"
                    source = "/etc/localtime"
                    readonly = true
                }

                volumes = [
                    "alloc/data/mail-state:/var/mail-state",
                    "alloc/data/logs:/var/log/mail",
                    "local/redis.conf:/etc/rspamd/local.d/redis.conf"
                ]

                logging {
                    type = "loki"
                    config {
                        loki-url = "${LOKI_URL}"
                        loki-retries = "3"
                        loki-batch-size = "400"
                        loki-external-labels = "nomad_dc=${NOMAD_DC},nomad_job=${NOMAD_JOB_NAME},nomad_group=${NOMAD_GROUP_NAME},nomad_task=${NOMAD_TASK_NAME},container_name={{.Name}}"
                    }
                }
            }

            template {
                data = file("./env.hcl.tmpl8")
                env = true
                destination = "local/env"
            }

            template {
                data = <<-EOF
                    {{- range nomadService "redis" -}}
                    servers = "{{ .Address }}:{{ .Port }}";
                    {{- end }}
                    expand_keys = true;
                    EOF
                destination = "local/redis.conf"
            }

            template {
                data = <<-EOF
                    {{- with nomadVar "ssl/lantey~2Eorg" -}}
                    {{- .full_chain -}}
                    {{- end -}}
                    EOF
                destination = "local/mail.lantey.org.crt"
                change_mode = "noop"
            }

            template {
                data = <<-EOF
                    {{- with nomadVar "ssl/lantey~2Eorg" -}}
                    {{- .key -}}
                    {{- end -}}
                    EOF
                destination = "secrets/mail.lantey.org.key"
                perms = "600"
                change_mode = "script"
                change_script {
                    command = "kill -s SIGHUP $(cat /run/dovecot/master.pid) && kill -s SIGHUP $(cat /var/spool/postfix/pid/master.pid)"
                    timeout = "30s"
                }
            }

            volume_mount {
                volume = "mailserver-config"
                destination = "/tmp/docker-mailserver"
            }

            volume_mount {
                volume = "mailserver-data"
                destination = "/var/mail"
            }
        }
    }
}
