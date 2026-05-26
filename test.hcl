job "postgres" {
    datacenters = ["bischheim"]

    update {
        max_parallel = 1
        healthy_deadline = "2m"
        progress_deadline = "6m"
    }
    
    group "postgres" {
        volume "pgdata" {
            type = "host"
            source = "pgdata"
            access_mode = "single-node-multi-writer"
            attachment_mode = "file-system"
        }

        network {
            port "postgres-db" {
                to = 5432
            }
        }

        service {
            name = "postgresql-direct"
            port = "postgres-db"
            provider = "nomad"

            check {
                name = "postgres_probe"
                type = "tcp"
                interval = "10s"
                timeout = "1s"
            }
        }

        count = 1

        task "postgres" {
            driver = "docker"
            config {
                //image = "gitea.lantey.org/lantey.org/pg-vchord-fr:pg18-v0.5.3-amd64"
                image = "pg-vchord-fr:pg18-v0.5.3-amd64"
                /*auth {
                    username = "virgile"
                    password = "${REGISTRY_PASS}"
                }*/
                ports = [ "postgres-db" ]
                shm_size = "${128 * 1000 * 1000}"
                args = [
                    "-c",
                    "config_file=/local/postgresql.conf"
                ]
            }

            template {
                data = <<-EOH
                    {{- with nomadVar "nomad/jobs/postgres" }}
                    POSTGRES_USER = "{{ .default_user }}"
                    POSTGRES_PASSWORD = "{{ .default_password }}"
                    REGISTRY_PASS = "{{ .DockerRegistryPassword }}"
                    {{ end -}}
                    EOH
                destination = "secrets/file.env"
                env = true
            }

            template {
                data = <<-EOH
                    listen_addresses = '*'
                    shared_preload_libraries = 'vchord.so'
                    unix_socket_directories = '/var/lib/postgresql/db-{{ env "NOMAD_ALLOC_INDEX" }}/18/docker'
                    autovacuum_worker_slots = 16	# autovacuum worker slots to allocate
                    # --- REPLICATION ---
                    wal_level = logical
                    EOH
                destination = "local/postgresql.conf"
            }

            env {
                PGDATA = "/var/lib/postgresql/db-${NOMAD_ALLOC_INDEX}/18/docker"
            }

            volume_mount {
                volume = "pgdata"
                destination = "/var/lib/postgresql"
            }

            resources {
                cpu = 2000
                memory = 8000
            }
        }
    }

    group "haproxy" {
        network {
            port "postgres" { }
        }

        service {
            name = "postgresql"
            port = "postgres"
            provider = "nomad"
        }

        task "haproxy" {
            driver = "docker"
            config {
                image = "haproxy:3.3-alpine"
                args = [
                    "-f",
                    "/local/haproxy.conf"
                ]
                ports = [ "postgres" ]
            }

            resources {
                cores = 1
            }

            template {
                data = <<-EOH
                    global
                        daemon

                    defaults
                        mode tcp
                        timeout client 10s
                        timeout connect 5s
                        timeout server 60s
                    
                    frontend postgresql_front
                        bind :{{ env "NOMAD_PORT_postgres" }}
                        default_backend postgresql_back
                    
                    backend postgresql_back
                        balance roundrobin
                        #option pgsql-check haproxy
                        {{- range nomadService "postgresql-direct" }}
                        server postgres{{ .Port }} {{ .Address }}:{{ .Port }} check
                        {{- end }}

                    EOH
                destination = "local/haproxy.conf"
                change_mode = "signal"
                change_signal = "SIGHUP"
            }
        }
    }
}
