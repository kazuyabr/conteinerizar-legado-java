#!/bin/bash

echo "============================================"
echo "  DOCKER-LEGACY - Auto-Discovery Engine"
echo "  Java 7 / Tomcat 7 / Ant Build"
echo "============================================"

SRC_DIR="/app/src"
TOMCAT_HOME="${CATALINA_HOME:-/opt/tomcat}"
WEBAPPS_DIR="$TOMCAT_HOME/webapps"
DEPS_DIR="$SRC_DIR/docker/deps"
BUILD_DIR="/tmp/build"
BUILD_SRC="/build/src"
DEPS_BUILD="/build/deps"
LOG_FILE="/tmp/entrypoint.log"
CACHE_MARKER="/build/.build_complete"
DEPS_MARKER="/build/.deps_complete"
TEMPLATE_CONF_DIR="/opt/docker-templates/conf"

# ============================================
# CONFIGURACAO (edite conforme necessario)
# ============================================
# Padrao de nomes dos projetos (glob pattern)
# Ex: "npco*" escaneia apenas pastas que comecam com "npco"
# Ex: "*" escaneia todas as pastas (usar IGNORE_PATTERN para filtrar)
PROJECT_PATTERN="*"

# Projetos ignorados (regex separada por |)
# Inclui pastas de libs, pastas do Eclipse, e pastas nao-projeto
# Usar ^ e $ para correspondencia exata quando necessario
IGNORE_PATTERN="^.*-lib-.*$|^Servers$|^RemoteSystemsTempFiles$|^WDE$|^automation$|^base$|^br$|^docker$|^docker-legacy$|^graft$|^node_modules$|^npco_gestores$"
ACTIVE_PROJECTS_REGEX="^(npco_base|npco|npco_analise)$"

# Target Ant para WARs (create-war evita EAR)
WAR_ANT_TARGET="create-war"

# Target Ant para CORE (jar padrao)
CORE_ANT_TARGET=""

FORCE_REBUILD="false"
HOTRELOAD="false"
for arg in "$@"; do
    case "$arg" in
        --force-rebuild) FORCE_REBUILD="true" ;;
        --hotreload) HOTRELOAD="true" ;;
    esac
done

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

phase_start() {
    PHASE_START_TS=$(date +%s)
    log "--- INICIO: $1 ---"
}

phase_end() {
    local label="$1"
    local now_ts
    now_ts=$(date +%s)
    log "--- FIM: $label (duracao: $((now_ts - PHASE_START_TS))s) ---"
}

remove_incompatible_cdi_jars() {
    local web_inf_lib="$1"
    local jar_name
    for jar_name in \
        ; do
        if [ -f "$web_inf_lib/$jar_name" ]; then
            rm -f "$web_inf_lib/$jar_name"
            log "JAR removido por incompatibilidade com scanner CDI legado: $jar_name"
        fi
    done
}

remove_incompatible_classdirs() {
    local web_inf_classes="$1"
    local bad_dir="$web_inf_classes/br/com/bradesco/web/aq/application/security/intranet/loginmodules/impl"
    if [ -d "$bad_dir" ]; then
        rm -f "$bad_dir"/*.class 2>/dev/null || true
        log "Classes removidas por incompatibilidade com scanner CDI legado: $bad_dir"
    fi
}

ensure_login_mock_file() {
    local war_dir="$1"
    local classes_dir="$war_dir/WEB-INF/classes"
    mkdir -p "$classes_dir"

    if [ -f "$classes_dir/login-mock.xml" ]; then
        log "login-mock.xml preservado do WAR em $(basename "$war_dir")"
        return 0
    fi

    if [ -f "$war_dir/WEB-INF/login-mock.xml" ]; then
        cp "$war_dir/WEB-INF/login-mock.xml" "$classes_dir/login-mock.xml" || exit 1
        log "login-mock.xml copiado de WEB-INF para classes em $(basename "$war_dir")"
        return 0
    fi

    cp "$TEMPLATE_CONF_DIR/login-mock.xml" "$classes_dir/login-mock.xml" || exit 1
    log "login-mock.xml fallback aplicado em $(basename "$war_dir")"
}

sanitize_deployed_webapps() {
    local war_dir
    for war_dir in "$WEBAPPS_DIR"/*/; do
        [ -d "$war_dir" ] || continue
        remove_incompatible_cdi_jars "$war_dir/WEB-INF/lib"
        remove_incompatible_classdirs "$war_dir/WEB-INF/classes"
    done
}

ensure_root_redirect() {
    local app_dir="$1"
    local target="$2"
    mkdir -p "$app_dir"
    cat > "$app_dir/index.jsp" <<EOF
<% response.sendRedirect(request.getContextPath() + "$target"); %>
EOF
}

recreate_owb_shim() {
    mkdir -p /tmp/owb-shim/org/apache/webbeans/el
    cat <<'JAVAEOF' > /tmp/owb-shim/org/apache/webbeans/el/WebBeansELResolver.java
package org.apache.webbeans.el;
public class WebBeansELResolver extends org.apache.webbeans.el22.WebBeansELResolver {
    private static final long serialVersionUID = 1L;
    public WebBeansELResolver() { super(); }
}
JAVAEOF
    local shim_jar=$(find "$WEBAPPS_DIR" -path "*/openwebbeans-el22-*.jar" -type f 2>/dev/null | head -1)
    local javac_bin
    javac_bin=$(command -v javac 2>/dev/null || true)
    if [ -n "$shim_jar" ]; then
        if [ -n "$javac_bin" ] && "$javac_bin" -source 1.7 -target 1.7 -cp "$TOMCAT_HOME/lib/el-api.jar:$shim_jar" /tmp/owb-shim/org/apache/webbeans/el/WebBeansELResolver.java && \
        jar cf /tmp/openwebbeans-el-shim.jar -C /tmp/owb-shim org/apache/webbeans/el/WebBeansELResolver.class; then
        # OWB pertence ao classloader de cada WAR, junto com suas dependencias.
        for d in "$WEBAPPS_DIR"/*/WEB-INF/lib; do
            [ -d "$d" ] || continue
            cp /tmp/openwebbeans-el-shim.jar "$d/openwebbeans-el-1.2.1.jar" || exit 1
        done
        log "Shim openwebbeans-el recriado"
        else
            log "ERRO: falha ao criar shim openwebbeans-el; deploy interrompido"
            exit 1
        fi
    fi
}

start_tomcat_legacy() {
    # Seed dos templates apenas quando o volume persistente ainda nao foi inicializado
    if [ ! -f "/conf/application-tu.properties" ] && [ -f "$TEMPLATE_CONF_DIR/application-tu.properties.example" ]; then
        cp "$TEMPLATE_CONF_DIR/application-tu.properties.example" "/conf/application-tu.properties"
        apply_tu_defaults "/conf/application-tu.properties"
        log "Config TU criada a partir do template"
    fi

    if [ ! -f "/conf/application-tu.properties.example" ] && [ -f "$TEMPLATE_CONF_DIR/application-tu.properties.example" ]; then
        cp "$TEMPLATE_CONF_DIR/application-tu.properties.example" "/conf/application-tu.properties.example"
    fi

    if [ ! -f "/conf/context.xml" ] && [ -f "$TEMPLATE_CONF_DIR/context.xml.example" ]; then
        cp "$TEMPLATE_CONF_DIR/context.xml.example" "/conf/context.xml"
        log "Context.xml criada a partir do template (preencha com credenciais reais)"
    fi

    if [ ! -f "/conf/context.xml.example" ] && [ -f "$TEMPLATE_CONF_DIR/context.xml.example" ]; then
        cp "$TEMPLATE_CONF_DIR/context.xml.example" "/conf/context.xml.example"
    fi

    mkdir -p "/conf/intranet/npco" "/conf/resources/intranet/NPCD" "$TOMCAT_HOME/logs"

    for war_dir in "$WEBAPPS_DIR"/*/; do
        [ -d "$war_dir" ] || continue
        wname=$(basename "$war_dir")
        case "$wname" in
            ROOT|manager|host-manager|docs|examples) continue ;;
        esac
        if [ -f "$war_dir/WEB-INF/application.properties" ]; then
            mkdir -p "/conf/intranet/$wname" "/conf/resources/intranet/NPCD" "$TOMCAT_HOME/logs"
            if [ ! -f "/conf/intranet/$wname/application.properties" ]; then
                if [ -f "/conf/application-tu.properties" ]; then
                    cp "/conf/application-tu.properties" "/conf/intranet/$wname/application.properties" 2>/dev/null
                    apply_tu_defaults "/conf/intranet/$wname/application.properties"
                    log "Config TU criada para $wname"
                else
                    cp "$war_dir/WEB-INF/application.properties" "/conf/intranet/$wname/application.properties" 2>/dev/null
                    log "Config copiada de WebContent para $wname (sem config TU)"
                fi
            fi
            sed -i "s|^external.properties[[:space:]]*=.*|external.properties=/opt/tomcat/webapps/$wname/WEB-INF/application.properties|" "$war_dir/WEB-INF/application.properties" 2>/dev/null
            apply_tu_defaults "$war_dir/WEB-INF/application.properties"
            if [ -f "$war_dir/WEB-INF/classes/logback-catalog.xml" ] && [ ! -f "/conf/intranet/$wname/logback-catalog.xml" ]; then
                cp "$war_dir/WEB-INF/classes/logback-catalog.xml" "/conf/intranet/$wname/logback-catalog.xml" 2>/dev/null
                sed -i 's|suportedbdc_logs|/opt/tomcat/logs|g' "/conf/intranet/$wname/logback-catalog.xml" 2>/dev/null
            fi
            [ ! -f "/conf/intranet/$wname/externalMappingFile.properties" ] && touch "/conf/intranet/$wname/externalMappingFile.properties" 2>/dev/null
            if [ -f "/conf/context.xml" ]; then
                mkdir -p "$war_dir/META-INF"
                cp "/conf/context.xml" "$war_dir/META-INF/context.xml" 2>/dev/null
                log "Context.xml injetado em $wname"
            fi
            log "Config externa configurada para $wname"
        fi
    done

    log "Iniciando Tomcat 7..."
    log "============================================"
    log "  RESUMO DO DEPLOY:"
    log "  - ENDERECO: http://localhost:8080"
    for dir in "$WEBAPPS_DIR"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        case "$name" in
            ROOT|manager|host-manager|docs|examples) continue ;;
        esac
        log "    * $name"
    done
    log "============================================"
    cd "$TOMCAT_HOME/bin"
    exec ./catalina.sh run
}

# ============================================
# FUNCAO: Aplicar defaults TU em arquivo de config
# Substitui placeholders residuais por valores reais
# ============================================
apply_tu_defaults() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    # CWS
    sed -i 's|<IP_CWS>|10.193.93.48|g' "$cfg" 2>/dev/null
    sed -i 's|<PORTA_CWS>|3130|g' "$cfg" 2>/dev/null
    # FWOP
    sed -i 's|<URL_FWOP>|http://10.193.103.17/FWOP|g' "$cfg" 2>/dev/null
    # FileNet
    sed -i 's|<URL_FILENET_CE>|https://ecmweb.unitario.teste.bradesco.com.br/gccn_integracaofilenet_ce_ws/services/IntegracaoFileNetCE?wsdl|g' "$cfg" 2>/dev/null
    sed -i 's|<URL_FILENET_IMAGEM>|https://ecmweb.unitario.teste.bradesco.com.br/gccn_integracaofilenetceimagem_ws/services/IntegracaoFileNetCEImagem?wsdl|g' "$cfg" 2>/dev/null
    # Facade GCC
    sed -i 's|<URL_FACADE>|https://ecmweb.unitario.teste.bradesco.com.br/gccn_integracaofilenet_ce_ws/services/IntegracaoFileNetCE|g' "$cfg" 2>/dev/null
    # WSDE
    sed -i 's|<URL_WSDE>|http://10.192.60.133:9081/npco_dossie_ws/DossieEletronico?wsdl|g' "$cfg" 2>/dev/null
    # ContasMe
    sed -i 's|<URL_CONTASME>|http://10.194.57.136:10050/ContasMeService.svc?singleWsdl|g' "$cfg" 2>/dev/null
    # Usuarios GCC
    sed -i 's|<USUARIO_GCC>|intranet_npco_dusrecm1|g' "$cfg" 2>/dev/null
    sed -i 's|<USUARIO_GCC_MANAGER>|intranet_npco_dusrecm1|g' "$cfg" 2>/dev/null
    sed -i 's|<USUARIO_SEGuranca>|UAPNPCO|g' "$cfg" 2>/dev/null
    # Token convivencia (mock - desabilitado)
    sed -i 's|<URL_TOKEN>|http://localhost:0/mock-token|g' "$cfg" 2>/dev/null
    sed -i 's|<CLIENT_ID>|mock-client-id|g' "$cfg" 2>/dev/null
    sed -i 's|<CLIENT_SECRET>|mock-client-secret|g' "$cfg" 2>/dev/null
}

# ============================================
# FUNCAO: Iniciar Tomcat
# ============================================
start_tomcat() {
    # Seed dos templates apenas quando o volume persistente ainda nao foi inicializado
    if [ ! -f "/conf/application-tu.properties" ] && [ -f "$TEMPLATE_CONF_DIR/application-tu.properties.example" ]; then
        cp "$TEMPLATE_CONF_DIR/application-tu.properties.example" "/conf/application-tu.properties"
        apply_tu_defaults "/conf/application-tu.properties"
        log "Config TU criada a partir do template"
    fi

    if [ ! -f "/conf/application-tu.properties.example" ] && [ -f "$TEMPLATE_CONF_DIR/application-tu.properties.example" ]; then
        cp "$TEMPLATE_CONF_DIR/application-tu.properties.example" "/conf/application-tu.properties.example"
    fi

    if [ ! -f "/conf/context.xml" ] && [ -f "$TEMPLATE_CONF_DIR/context.xml.example" ]; then
        cp "$TEMPLATE_CONF_DIR/context.xml.example" "/conf/context.xml"
        log "Context.xml criada a partir do template (preencha com credenciais reais)"
    fi

    if [ ! -f "/conf/context.xml.example" ] && [ -f "$TEMPLATE_CONF_DIR/context.xml.example" ]; then
        cp "$TEMPLATE_CONF_DIR/context.xml.example" "/conf/context.xml.example"
    fi

    # Garantir que a raiz local de configuracao exista antes do deploy
    mkdir -p "/conf/intranet/npco" "/conf/resources/intranet/NPCD" "$TOMCAT_HOME/logs"
    
    # Criar diretorios locais de configuracao
    for war_dir in "$WEBAPPS_DIR"/*/; do
        [ -d "$war_dir" ] || continue
        wname=$(basename "$war_dir")
        case "$wname" in
            ROOT|manager|host-manager|docs|examples) continue ;;
        esac
        if [ -f "$war_dir/WEB-INF/application.properties" ]; then
            mkdir -p "/conf/intranet/$wname" "/conf/resources/intranet/NPCD" "$TOMCAT_HOME/logs"
            # Criar config local apenas na primeira vez; depois respeitar overrides do volume
            if [ ! -f "/conf/intranet/$wname/application.properties" ]; then
                if [ -f "/conf/application-tu.properties" ]; then
                    cp "/conf/application-tu.properties" "/conf/intranet/$wname/application.properties" 2>/dev/null
                    apply_tu_defaults "/conf/intranet/$wname/application.properties"
                    log "Config TU criada para $wname"
                else
                    cp "$war_dir/WEB-INF/application.properties" "/conf/intranet/$wname/application.properties" 2>/dev/null
                    log "Config copiada de WebContent para $wname (sem config TU)"
                fi
            fi
            # O WAR aponta para a configuracao externa local, como no Eclipse.
            sed -i "s|^external.properties[[:space:]]*=.*|external.properties=/conf/intranet/$wname/application.properties|" "$war_dir/WEB-INF/application.properties"
            apply_tu_defaults "/conf/intranet/$wname/application.properties"
            # Copiar logback-catalog.xml se existir nas classes e remover dependencias de caminho legado
            if [ -f "$war_dir/WEB-INF/classes/logback-catalog.xml" ] && [ ! -f "/conf/intranet/$wname/logback-catalog.xml" ]; then
                cp "$war_dir/WEB-INF/classes/logback-catalog.xml" "/conf/intranet/$wname/logback-catalog.xml" 2>/dev/null
                sed -i 's|suportedbdc_logs|/opt/tomcat/logs|g' "/conf/intranet/$wname/logback-catalog.xml" 2>/dev/null
            fi
            # externalMappingFile vazio se nao existir
            [ ! -f "/conf/intranet/$wname/externalMappingFile.properties" ] && touch "/conf/intranet/$wname/externalMappingFile.properties" 2>/dev/null
            # Injetar context.xml com DataSource Oracle
            if [ -f "/conf/context.xml" ]; then
                mkdir -p "$war_dir/META-INF"
                cp "/conf/context.xml" "$war_dir/META-INF/context.xml" 2>/dev/null
                # O nome JAAS e declarado por cada WAR (LDAPLogin ou MockLogin).
                local jaas_name
                jaas_name=$(sed -n 's/^[[:space:]]*\([A-Za-z0-9_]*\)[[:space:]]*{.*/\1/p' "$war_dir/WEB-INF/jaas.config" | head -1)
                if [ -n "$jaas_name" ]; then
                    # JAAS global e sobrescrito pelos listeners dos WARs. Isolar por Realm.
                    cp "$war_dir/WEB-INF/jaas.config" "$war_dir/WEB-INF/classes/docker-legacy-jaas.config" || exit 1
                    if grep -q 'BradescoIntranetMockLMImpl' "$war_dir/WEB-INF/jaas.config"; then
                        ensure_login_mock_file "$war_dir"
                    fi
                    sed -i "s/appName=\"[^\"]*\"/appName=\"$jaas_name\" configFile=\"docker-legacy-jaas.config\"/" "$war_dir/META-INF/context.xml"
                fi
                log "Context.xml injetado em $wname"
            fi
            log "Config externa configurada para $wname"
        fi
        # A referencia Eclipse tambem nao possui esse arquivo opcional.
        # Remover somente a referencia ausente, mantendo os beans anotados/JARs.
        if [ -f "$war_dir/WEB-INF/web.xml" ]; then
            cp "$TEMPLATE_CONF_DIR/faces-docker-legacy.xml" "$war_dir/WEB-INF/faces-docker-legacy.xml" || exit 1
            if ! grep -q '/WEB-INF/faces-docker-legacy.xml' "$war_dir/WEB-INF/web.xml"; then
                sed -i 's|/WEB-INF/faces-config.xml,|/WEB-INF/faces-config.xml,/WEB-INF/faces-docker-legacy.xml,|' "$war_dir/WEB-INF/web.xml"
            fi
            if [ ! -f "$war_dir/WEB-INF/faces-managed-beans-config.xml" ]; then
                sed -i 's|/WEB-INF/faces-managed-beans-config.xml,\{0,1\}||g' "$war_dir/WEB-INF/web.xml"
            fi
            sed -i 's|;:/components.taglib.xml|;/components.taglib.xml|g' "$war_dir/WEB-INF/web.xml"
            if [ ! -f "$war_dir/components.taglib.xml" ]; then
                if [ -f "$war_dir/WEB-INF/classes/META-INF/components.taglib.xml" ]; then
                    sed -i 's|;/components.taglib.xml|;/WEB-INF/classes/META-INF/components.taglib.xml|g' "$war_dir/WEB-INF/web.xml"
                else
                    sed -i 's|;/components.taglib.xml||g' "$war_dir/WEB-INF/web.xml"
                fi
            fi
        fi
    done

    log "Iniciando Tomcat 7..."
    log "============================================"
    log "  RESUMO DO DEPLOY:"
    log "  - ENDERECO: http://localhost:8080"
    for dir in "$WEBAPPS_DIR"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        case "$name" in
            ROOT|manager|host-manager|docs|examples) continue ;;
        esac
        log "    * $name"
    done
    log "============================================"
    cd "$TOMCAT_HOME/bin"
    exec ./catalina.sh run
}

# ============================================
# FUNCAO: Gerar hash das fontes (rapido)
# ============================================
source_hash() {
    local hash_input=""
    local project_dir
    for project_dir in "$@"; do
        [ -d "$project_dir" ] || continue
        hash_input="$hash_input $(find "$project_dir/JavaSource" "$project_dir/WebContent" "$project_dir/Empacotamento/Ant" -type f 2>/dev/null | sort | xargs stat -c '%Y %n' 2>/dev/null)"
        [ -f "$project_dir/WebContent/index.jsp" ] && hash_input="$hash_input $(stat -c '%Y %n' "$project_dir/WebContent/index.jsp" 2>/dev/null)"
    done
    printf '%s' "$hash_input" | md5sum | cut -d' ' -f1
}

# ============================================
# CHECK DE CACHE
# ============================================
if [ -f "$CACHE_MARKER" ] && [ "$FORCE_REBUILD" = "false" ]; then
    log "Build cache encontrado em $CACHE_MARKER"
    
    # Verificar hash das fontes vs hash salvo
    CURRENT_HASH=$(source_hash "$SRC_DIR/npco_base" "$SRC_DIR/npco" "$SRC_DIR/npco_analise")
    SAVED_HASH=$(cat /build/.source_hash 2>/dev/null || echo "none")
    
    if [ "$CURRENT_HASH" = "$SAVED_HASH" ]; then
        log "Fontes inalteradas (hash: $CURRENT_HASH). Pulando build."
        sanitize_deployed_webapps
        ensure_root_redirect "$WEBAPPS_DIR/npco" "/content/index.xhtml"
        ensure_root_redirect "$WEBAPPS_DIR/npco_analise" "/content/index.xhtml"
        recreate_owb_shim
        start_tomcat
    fi
    
    log "Mudancas detectadas (hash mudou). Executando rebuild..."
fi

log "Diretorio fonte: $SRC_DIR"
log "Dependencias: $DEPS_DIR"
log "Force rebuild: $FORCE_REBUILD"
log "Hotreload: $HOTRELOAD"

if [ ! -d "$SRC_DIR" ]; then
    log "ERRO: Diretorio fonte nao encontrado: $SRC_DIR"
    exit 1
fi

mkdir -p "$BUILD_DIR" "$BUILD_SRC" "$DEPS_BUILD"

# ============================================
# FASE 1: ESCANEAR E CLASSIFICAR PROJETOS
# ============================================
log "=== FASE 1: Escaneando projetos ==="

CORE_SRC=""
WAR_SRCS=()

for project_dir in "$SRC_DIR"/*/; do
    [ -d "$project_dir" ] || continue

    project_name=$(basename "$project_dir")

    # Filtrar por padrao de nome (se nao for "*")
    if [ "$PROJECT_PATTERN" != "*" ]; then
        case "$project_name" in
            $PROJECT_PATTERN) ;; # match
            *) continue ;;
        esac
    fi

    has_java_source="false"
    has_web_content="false"

    [ -d "$project_dir/JavaSource" ] && has_java_source="true"
    [ -d "$project_dir/WebContent" ] && has_web_content="true"

    log "Projeto: $project_name | JavaSource=$has_java_source | WebContent=$has_web_content"

    # Ignorar pastas de libs e projetos configurados
    if echo "$project_name" | grep -qE "$IGNORE_PATTERN"; then
        log "  -> Ignorado (regra: $IGNORE_PATTERN)"
        continue
    fi

    if ! echo "$project_name" | grep -qE "$ACTIVE_PROJECTS_REGEX"; then
        log "  -> Ignorado (fora do conjunto ativo: $ACTIVE_PROJECTS_REGEX)"
        continue
    fi

    is_core="false"
    if [ -f "$project_dir/bin/${project_name}.jar" ] || [ -f "$project_dir/target/${project_name}.jar" ]; then
        is_core="true"
    fi

    if [ "$is_core" = "true" ]; then
        if [ -z "$CORE_SRC" ]; then
            CORE_SRC="$project_dir"
            log "  -> CORE (JAR)"
        else
            log "  -> AVISO: Multiplo CORE, usando o primeiro"
        fi
    elif [ "$has_web_content" = "true" ]; then
        WAR_SRCS+=("$project_dir")
        log "  -> WAR (Site)"
    else
        log "  -> Ignorado"
    fi
done

if [ -z "$CORE_SRC" ]; then
    log "ERRO: Nenhum projeto CORE (JAR) encontrado!"
    exit 1
fi

if [ ${#WAR_SRCS[@]} -eq 0 ]; then
    log "ERRO: Nenhum projeto WAR encontrado!"
    exit 1
fi

log "CORE: $(basename "$CORE_SRC")"
log "WARs: ${#WAR_SRCS[@]}"

# ============================================
# COPIAR FONTES P/ FS NATIVO DO CONTAINER
# ============================================
copy_dependency_dir() {
    local dep_name="$1"
    if [ -d "$DEPS_DIR/$dep_name" ]; then
        log "Copiando dependencia: $dep_name -> $DEPS_BUILD/$dep_name"
        cp -a "$DEPS_DIR/$dep_name" "$DEPS_BUILD/"
        log "Dependencia copiada: $dep_name"
    else
        log "AVISO: dependencia nao encontrada em $DEPS_DIR/$dep_name"
    fi
}

if [ -f "$DEPS_MARKER" ] && [ "$FORCE_REBUILD" = "false" ]; then
    log "Dependencias em cache encontradas em $DEPS_MARKER. Pulando copia."
else
    phase_start "Copia de dependencias"
    log "Copiando dependencias selecionadas -> $DEPS_BUILD"
    rm -rf "$DEPS_BUILD"
    mkdir -p "$DEPS_BUILD"
    copy_dependency_dir "websphere_lib"
    copy_dependency_dir "intranet_mcnl_corporativo_negocio_v1"
    copy_dependency_dir "intranet_eint_corporativo_negocio_v3"
    copy_dependency_dir "intranet_eint_corporativo_sistema_v3"
    copy_dependency_dir "intranet_npco_base_negocio_v1"
    copy_dependency_dir "j2ee"
    copy_dependency_dir "itextpdf"
    touch "$DEPS_MARKER"
    phase_end "Copia de dependencias"
fi

copy_project() {
    local src="$1"
    local name
    name=$(basename "$src")
    log "Copiando projeto $name -> $BUILD_SRC/$name"
    rm -rf "$BUILD_SRC/$name"
    mkdir -p "$BUILD_SRC/$name"
    local copied_items=0
    for item in JavaSource WebContent Empacotamento; do
        if [ -e "$src/$item" ]; then
            log "  -> copiando $name/$item"
            cp -a "$src/$item" "$BUILD_SRC/$name/"
            copied_items=$((copied_items + 1))
        else
            log "  -> ausente: $name/$item"
        fi
    done
    if [ -f "$src/WebContent/index.jsp" ]; then
        cp -a "$src/WebContent/index.jsp" "$BUILD_SRC/$name/WebContent/"
        log "  -> copiando $name/WebContent/index.jsp"
    fi
    log "Projeto $name copiado com $copied_items diretorios principais"
}

phase_start "Copia de fontes"
copy_project "$CORE_SRC"
for w in "${WAR_SRCS[@]}"; do
    copy_project "$w"
done
phase_end "Copia de fontes"

CORE_PROJECT="$BUILD_SRC/$(basename "$CORE_SRC")"
WAR_PROJECTS=()
for w in "${WAR_SRCS[@]}"; do
    WAR_PROJECTS+=("$BUILD_SRC/$(basename "$w")")
done

# ============================================
# PATCHES AUTOMATICOS
# ============================================

# Patch SiteUtil.java: remover imports WebSphere especificos
SITEUTIL="$CORE_PROJECT/JavaSource/br/com/bradesco/web/base/utils/SiteUtil.java"
if [ -f "$SITEUTIL" ]; then
    sed -i '/^import com\.ibm\.wsspi\.security\.auth\.callback\.Constants;/d' "$SITEUTIL"
    sed -i '/^import com\.ibm\.wsspi\.security\.auth\.callback\.WSMappingCallbackHandlerFactory;/d' "$SITEUTIL"
    sed -i '/private static CredencialVO obterUsuarioSistemicoAcessoGCC/,/^    }/c\    private static CredencialVO obterUsuarioSistemicoAcessoGCC(String nomeRecurso) {\n        return null;\n    }' "$SITEUTIL"
    sed -i 's|org\.apache\.commons\.codec\.binary\.Base64\.encodeBase64String|javax.xml.bind.DatatypeConverter.printBase64Binary|g' "$SITEUTIL"
    log "SiteUtil.java patcheado"
fi

# Patch javac encoding (fontes windows-1252)
for b in "$BUILD_SRC"/*/Empacotamento/Ant/build.xml; do
    [ -f "$b" ] || continue
    if grep -q '<javac ' "$b" && ! grep -q 'encoding=' "$b"; then
        sed -i 's/<javac /<javac encoding="windows-1252" /g' "$b" 2>/dev/null
    fi
done
log "javac encoding patch aplicado (windows-1252)"

# ============================================
# FUNCOES AUXILIARES
# ============================================
prepare_build_dir() {
    local proj="$1"
    rm -rf "$proj/Empacotamento/Ant/Dist" 2>/dev/null || true
    rm -rf "$proj/WebContent/WEB-INF/classes" 2>/dev/null || true
}

generate_ant_flags() {
    local deps_xml="$1"
    local output_var="$2"
    local core_jar="$3"
    local project_name="$4"

    local flags=""
    flags="$flags -Dempacotamento.package.jar.name=${project_name}.jar"
    flags="$flags -Dempacotamento.caminho.pacote=bin"

    if [ -f "$deps_xml" ]; then
        while IFS= read -r line; do
            if echo "$line" | grep -q "dependencia-arquivo"; then
                local id_val=$(echo "$line" | grep -oP 'id="\K[^"]+')
                local caminho_val=$(echo "$line" | grep -oP 'caminho="\K[^"]+')
                local nome_val=$(echo "$line" | grep -oP 'nome="\K[^"]+')
                local folder=$(basename "$caminho_val" | tr '[:upper:]' '[:lower:]')
                [ "$folder" = "ibm_was_8_5" ] && folder="websphere_lib"
                if [ -n "$nome_val" ]; then
                    local dep_path="$DEPS_BUILD/$folder/$nome_val"
                    if [ ! -e "$dep_path" ]; then
                        local found=$(find "$DEPS_BUILD" -name "$nome_val" -type f 2>/dev/null | head -1)
                        [ -n "$found" ] && dep_path="$found"
                    fi
                    flags="$flags -Dempacotamento.pasta.dependencia.$id_val=$dep_path"
                else
                    flags="$flags -Dempacotamento.pasta.dependencia.$id_val=$DEPS_BUILD/$folder"
                fi
            elif echo "$line" | grep -q "dependencia-pasta"; then
                local id_val=$(echo "$line" | grep -oP 'id="\K[^"]+')
                local caminho_val=$(echo "$line" | grep -oP 'caminho="\K[^"]+')
                local folder=$(basename "$caminho_val" | tr '[:upper:]' '[:lower:]')
                [ "$folder" = "ibm_was_8_5" ] && folder="websphere_lib"
                local dep_path="$DEPS_BUILD/$folder"
                if [ ! -d "$dep_path" ]; then
                    local id_short=$(echo "$id_val" | sed 's/^id\.//')
                    if [ -d "$DEPS_BUILD/$id_short" ]; then
                        dep_path="$DEPS_BUILD/$id_short"
                    fi
                fi
                flags="$flags -Dempacotamento.pasta.dependencia.$id_val=$dep_path"
            fi
        done < "$deps_xml"
    fi

    if [ -n "$core_jar" ]; then
        flags="$flags -Dempacotamento.pasta.dependencia.id.npco_base=$core_jar"
    fi

    eval "$output_var=\"\$flags\""
}

# ============================================
# FASE 2: BUILD DO CORE (JAR)
# ============================================
log "=== FASE 2: Build do CORE ==="

CORE_NAME=$(basename "$CORE_PROJECT")
CORE_ANT_DIR="$CORE_PROJECT/Empacotamento/Ant"
CORE_DEPS_XML="$CORE_ANT_DIR/dependencias.xml"

if [ ! -d "$CORE_ANT_DIR" ]; then
    log "ERRO: Pasta Ant nao encontrada: $CORE_ANT_DIR"
    exit 1
fi

generate_ant_flags "$CORE_DEPS_XML" "CORE_FLAGS" "" "$CORE_NAME"
log "CORE_FLAGS: $CORE_FLAGS"

phase_start "Build CORE $CORE_NAME"
log "Buildando $CORE_NAME com Ant..."
prepare_build_dir "$CORE_PROJECT"
cd "$CORE_ANT_DIR"
ant $CORE_ANT_TARGET $CORE_FLAGS 2>&1 | tee -a "$LOG_FILE"
rc=${PIPESTATUS[0]}

if [ $rc -ne 0 ]; then
    log "ERRO: Falha no build do CORE (rc=$rc)"
    exit 1
fi
phase_end "Build CORE $CORE_NAME"

CORE_JAR=$(find "$CORE_PROJECT/bin" -name "*.jar" -type f 2>/dev/null | head -1)
[ -z "$CORE_JAR" ] && CORE_JAR=$(find "$CORE_PROJECT/target" -name "*.jar" -type f 2>/dev/null | head -1)
[ -z "$CORE_JAR" ] && CORE_JAR=$(find "$CORE_PROJECT/Empacotamento/Ant/Dist" -name "*.jar" -type f 2>/dev/null | head -1)

if [ -z "$CORE_JAR" ]; then
    log "ERRO: JAR do CORE nao encontrado"
    exit 1
fi

log "CORE JAR: $CORE_JAR"

mkdir -p /build/dist
cp "$CORE_JAR" /build/dist/core.jar
for deps_dir in "$DEPS_BUILD"/*/; do
    [ -d "$deps_dir" ] || continue
    if [ -f "$deps_dir/npco_base.jar" ]; then
        cp -f "$CORE_JAR" "$deps_dir/npco_base.jar" 2>/dev/null
    fi
done

# ============================================
# FASE 3: BUILD DOS WARs
# ============================================
log "=== FASE 3: Build dos WARs ==="

FAILED_WARS=()

for war_dir in "${WAR_PROJECTS[@]}"; do
    war_name=$(basename "$war_dir")
    log "--- Buildando: $war_name ---"

    WAR_ANT_DIR="$war_dir/Empacotamento/Ant"
    WAR_DEPS_XML="$WAR_ANT_DIR/dependencias.xml"

    if [ ! -d "$WAR_ANT_DIR" ]; then
        log "AVISO: Pasta Ant nao encontrada para $war_name"
        continue
    fi

    generate_ant_flags "$WAR_DEPS_XML" "WAR_FLAGS" "/build/dist/core.jar" "$war_name"
    log "WAR_FLAGS: $WAR_FLAGS"

    phase_start "Build WAR $war_name"
    prepare_build_dir "$war_dir"
    cd "$WAR_ANT_DIR"
    ant $WAR_ANT_TARGET $WAR_FLAGS 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}

    if [ $rc -ne 0 ]; then
        log "ERRO: Falha no build do $war_name (rc=$rc)"
        FAILED_WARS+=("$war_name")
        phase_end "Build WAR $war_name"
        continue
    fi

    WAR_FILE=$(find "$war_dir/Empacotamento/Ant/Dist" -name "*.war" -type f 2>/dev/null | head -1)

    if [ -n "$WAR_FILE" ]; then
        log "WAR gerado: $WAR_FILE"
        rm -rf "$WEBAPPS_DIR/$war_name"
        mkdir -p "$WEBAPPS_DIR/$war_name"
        cd "$WEBAPPS_DIR/$war_name"
        unzip -q -o "$WAR_FILE" 2>/dev/null || true
    else
        log "AVISO: WAR nao encontrado para $war_name, usando WebContent + classes"
        rm -rf "$WEBAPPS_DIR/$war_name"
        mkdir -p "$WEBAPPS_DIR/$war_name"
            cp -r "$war_dir/WebContent"/* "$WEBAPPS_DIR/$war_name/" 2>/dev/null || true
        if [ -d "$war_dir/Empacotamento/Ant/Dist/classes" ]; then
            mkdir -p "$WEBAPPS_DIR/$war_name/WEB-INF/classes"
            cp -r "$war_dir/Empacotamento/Ant/Dist/classes"/* "$WEBAPPS_DIR/$war_name/WEB-INF/classes/" 2>/dev/null || true
        fi
    fi

    ensure_root_redirect "$WEBAPPS_DIR/$war_name" "/content/index.xhtml"

    log "Deploy: $war_name -> $WEBAPPS_DIR/$war_name"
    phase_end "Build WAR $war_name"
done

# ============================================
# FASE 4: INJETAR CORE JAR NOS WARs
# ============================================
log "=== FASE 4: Injetando CORE JAR nos WARs ==="

for war_dir in "${WAR_PROJECTS[@]}"; do
    war_name=$(basename "$war_dir")
    WEB_INF_LIB="$WEBAPPS_DIR/$war_name/WEB-INF/lib"

    if [ -d "$WEB_INF_LIB" ]; then
        cp /build/dist/core.jar "$WEB_INF_LIB/$(basename "$CORE_JAR")" 2>/dev/null || true
        log "CORE JAR injetado em $war_name/WEB-INF/lib/"
        remove_incompatible_cdi_jars "$WEB_INF_LIB"
    fi
done

# ============================================
# FASE 5: SHIM + INICIALIZACAO
# ============================================
log "=== FASE 5: Finalizando ==="
recreate_owb_shim
log "Shim OpenWebBeans processado"

rm -rf "$BUILD_DIR"
touch "$CACHE_MARKER"
source_hash "$SRC_DIR/npco_base" "$SRC_DIR/npco" "$SRC_DIR/npco_analise" > /build/.source_hash
log "Cache de build atualizado: $CACHE_MARKER"

start_tomcat
