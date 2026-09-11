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

# ============================================
# FUNCAO: Iniciar Tomcat
# ============================================
start_tomcat() {
    # Criar diretorios externos de configuracao
    for war_dir in "$WEBAPPS_DIR"/*/; do
        [ -d "$war_dir" ] || continue
        wname=$(basename "$war_dir")
        case "$wname" in
            ROOT|manager|host-manager|docs|examples) continue ;;
        esac
        if [ -f "$war_dir/WEB-INF/application.properties" ]; then
            mkdir -p "/suportedbdc_config/intranet/$wname"
            # Usar config externa se existir (volume montado do host)
            if [ ! -f "/suportedbdc_config/intranet/$wname/application.properties" ]; then
                # Config externa nao existe - usar config TU padrao
                if [ -f "/conf/application-tu.properties" ]; then
                    cp "/conf/application-tu.properties" "/suportedbdc_config/intranet/$wname/application.properties" 2>/dev/null
                    log "Config TU padrao aplicada para $wname"
                else
                    cp "$war_dir/WEB-INF/application.properties" "/suportedbdc_config/intranet/$wname/application.properties" 2>/dev/null
                    log "Config copiada de WebContent para $wname (sem config externa nem TU padrao)"
                fi
            else
                log "Config externa existente mantida para $wname"
            fi
            # Corrigir external.properties para caminho completo do arquivo
            sed -i "s|^external.properties = /suportedbdc_config/intranet/$wname.*|external.properties = /suportedbdc_config/intranet/$wname/application.properties|" "$war_dir/WEB-INF/application.properties" 2>/dev/null
            # Copiar logback-catalog.xml se existir nas classes
            [ -f "$war_dir/WEB-INF/classes/logback-catalog.xml" ] && [ ! -f "/suportedbdc_config/intranet/$wname/logback-catalog.xml" ] && cp "$war_dir/WEB-INF/classes/logback-catalog.xml" "/suportedbdc_config/intranet/$wname/logback-catalog.xml" 2>/dev/null
            # externalMappingFile vazio se nao existir
            [ ! -f "/suportedbdc_config/intranet/$wname/externalMappingFile.properties" ] && touch "/suportedbdc_config/intranet/$wname/externalMappingFile.properties" 2>/dev/null
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
# FUNCAO: Gerar hash das fontes (rapido)
# ============================================
source_hash() {
    local src_dir="$1"
    # Hash baseado em timestamps dos dirs pai (muito mais rapido que find)
    find "$src_dir" -maxdepth 2 -name "*.java" -o -name "*.xml" 2>/dev/null | xargs stat -c '%Y' 2>/dev/null | sort | md5sum | cut -d' ' -f1
}

# ============================================
# CHECK DE CACHE
# ============================================
if [ -f "$CACHE_MARKER" ] && [ "$FORCE_REBUILD" = "false" ]; then
    log "Build cache encontrado em $CACHE_MARKER"
    
    # Verificar hash das fontes vs hash salvo
    CURRENT_HASH=$(source_hash "$SRC_DIR")
    SAVED_HASH=$(cat /build/.source_hash 2>/dev/null || echo "none")
    
    if [ "$CURRENT_HASH" = "$SAVED_HASH" ]; then
        log "Fontes inalteradas (hash: $CURRENT_HASH). Pulando build."
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
log "Copiando dependencias -> $DEPS_BUILD"
rm -rf "$DEPS_BUILD"
mkdir -p "$DEPS_BUILD"
for item in "$DEPS_DIR"/*; do
    [ -e "$item" ] || continue
    cp -a "$item" "$DEPS_BUILD/"
done

copy_project() {
    local src="$1"
    local name
    name=$(basename "$src")
    log "Copiando $name -> $BUILD_SRC/$name"
    rm -rf "$BUILD_SRC/$name"
    mkdir -p "$BUILD_SRC/$name"
    for item in "$src"/*; do
        [ -e "$item" ] || continue
        local b
        b=$(basename "$item")
        case "$b" in
            bin|target|.git|.claude|graft|node_modules|.gradle|.mvn|.settings|.project|.classpath) continue ;;
        esac
        cp -a "$item" "$BUILD_SRC/$name/"
    done
}

copy_project "$CORE_SRC"
for w in "${WAR_SRCS[@]}"; do
    copy_project "$w"
done

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

recreate_owb_shim() {
    mkdir -p /tmp/owb-shim/org/apache/webbeans/el
    cat > /tmp/owb-shim/org/apache/webbeans/el/WebBeansELResolver.java << 'JAVAEOF'
package org.apache.webbeans.el;
public class WebBeansELResolver extends org.apache.webbeans.el22.WebBeansELResolver {
    private static final long serialVersionUID = 1L;
    public WebBeansELResolver() { super(); }
}
JAVAEOF
    local shim_jar=$(find "$WEBAPPS_DIR" -path "*/openwebbeans-el22-*.jar" -type f 2>/dev/null | head -1)
    if [ -n "$shim_jar" ]; then
        /usr/lib/jvm/zulu7-ca-amd64/bin/javac -cp "/opt/tomcat/lib/el-api.jar:$shim_jar" /tmp/owb-shim/org/apache/webbeans/el/WebBeansELResolver.java 2>/dev/null && \
        /usr/lib/jvm/zulu7-ca-amd64/bin/jar cf /tmp/openwebbeans-el-shim.jar -C /tmp/owb-shim org/apache/webbeans/el/WebBeansELResolver.class 2>/dev/null && \
        for d in "$WEBAPPS_DIR"/*/WEB-INF/lib; do
            [ -d "$d" ] || continue
            cp /tmp/openwebbeans-el-shim.jar "$d/openwebbeans-el-1.2.1.jar" 2>/dev/null
        done && log "Shim openwebbeans-el recriado" || log "AVISO: falha ao criar shim openwebbeans-el"
    fi
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

log "Buildando $CORE_NAME com Ant..."
prepare_build_dir "$CORE_PROJECT"
cd "$CORE_ANT_DIR"
ant $CORE_ANT_TARGET $CORE_FLAGS 2>&1 | tee -a "$LOG_FILE"
rc=${PIPESTATUS[0]}

if [ $rc -ne 0 ]; then
    log "ERRO: Falha no build do CORE (rc=$rc)"
    exit 1
fi

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

    prepare_build_dir "$war_dir"
    cd "$WAR_ANT_DIR"
    ant $WAR_ANT_TARGET $WAR_FLAGS 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}

    if [ $rc -ne 0 ]; then
        log "ERRO: Falha no build do $war_name (rc=$rc)"
        FAILED_WARS+=("$war_name")
        continue
    fi

    WAR_FILE=$(find "$war_dir/Empacotamento/Ant/Dist" -name "*.war" -type f 2>/dev/null | head -1)

    if [ -n "$WAR_FILE" ]; then
        log "WAR gerado: $WAR_FILE"
        mkdir -p "$WEBAPPS_DIR/$war_name"
        cd "$WEBAPPS_DIR/$war_name"
        unzip -q -o "$WAR_FILE" 2>/dev/null || true
    else
        log "AVISO: WAR nao encontrado para $war_name, usando WebContent + classes"
        mkdir -p "$WEBAPPS_DIR/$war_name"
        cp -r "$war_dir/WebContent"/* "$WEBAPPS_DIR/$war_name/" 2>/dev/null || true
        if [ -d "$war_dir/Empacotamento/Ant/Dist/classes" ]; then
            mkdir -p "$WEBAPPS_DIR/$war_name/WEB-INF/classes"
            cp -r "$war_dir/Empacotamento/Ant/Dist/classes"/* "$WEBAPPS_DIR/$war_name/WEB-INF/classes/" 2>/dev/null || true
        fi
    fi

    log "Deploy: $war_name -> $WEBAPPS_DIR/$war_name"
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
    fi
done

# ============================================
# FASE 5: SHIM + INICIALIZACAO
# ============================================
log "=== FASE 5: Finalizando ==="
recreate_owb_shim

rm -rf "$BUILD_DIR"
touch "$CACHE_MARKER"
source_hash "$SRC_DIR" > /build/.source_hash

start_tomcat
