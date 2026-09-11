# Docker Legacy - Ambiente Local para Monolito Java 7

Ambiente Docker isolado para rodar monolito modular legado Java 7, removendo a dependência do servidor embutido do Eclipse.

## Pré-requisitos

- Docker Desktop instalado e rodando
- Docker Compose v2+
- Estrutura de projetos no padrão Eclipse WTP:
  - `JavaSource/` - Código-fonte Java
  - `WebContent/` - Arquivos web (JSPs, HTML, WEB-INF)
  - `Empacotamento/Ant/` - Build script Ant + dependencias.xml

## Estrutura Esperada

```
ANALISEIA/
├── docker-legacy/          # Este repositório
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── entrypoint.sh
│   └── conf/server.xml
├── docker/
│   └── deps/               # Dependências (JARs)
│       ├── j2ee/
│       ├── websphere_lib/
│       ├── itextpdf/
│       └── ...
└── npco_base/              # CORE (JAR)
    ├── JavaSource/
    ├── WebContent/
    └── Empacotamento/Ant/
        ├── build.xml
        └── dependencias.xml
```

## Uso Rápido

```bash
# 1. Navegue até a pasta do docker-legacy
cd docker-legacy

# 2. Suba o ambiente (1ª vez: ~15-20 min, depois: ~5 seg)
docker compose up -d

# 3. Acompanhe os logs
docker compose logs -f tomcat

# 4. Acesse a aplicação
# http://localhost:8080/npco
```

## Comandos Úteis

```bash
# Subir em background
docker compose up -d

# Parar ambiente
docker compose down

# Rebuild completo (após alterar código-fonte)
docker compose run --rm tomcat --force-rebuild

# Rebuild do Dockerfile (após alterar Dockerfile)
docker compose build --no-cache
docker compose up -d

# Ver logs em tempo real
docker compose logs -f tomcat

# Acessar shell do container
docker compose exec tomcat bash

# Verificar status
docker compose ps
```

## Comportamento de Cache

O `entrypoint.sh` implementa cache de build para otimizar reinicializações:

| Comportamento | Tempo Estimado |
|---------------|----------------|
| **1ª execução** | ~15-20 min |
| **Reinicializações** | ~5 seg |

### Como funciona

1. **1ª execução**: Copia fontes, compila CORE + WARs, deploy no Tomcat
2. **Marcador**: Cria `/build/.build_complete` após build bem-sucedido
3. **Reinicializações**: Verifica marcador → pula build → inicia Tomcat

### Forçar rebuild

```bash
# Opção 1: Usar flag
docker compose run --rm tomcat --force-rebuild

# Opção 2: Deletar marcador
docker compose exec tomcat rm /build/.build_complete
docker compose restart tomcat
```

## Auto-Descoberta

O `entrypoint.sh` executa automaticamente:

1. **Escaneamento**: Identifica projetos CORE vs WAR
   - CORE = tem `bin/npco_base.jar` ou `target/npco_base.jar`
   - WAR = tem `WebContent/`
   - Ignora `*-lib-*` (pastas de dependências)
2. **Cópia**: Copia fontes para `/build/src` (FS nativo, não bind mount)
3. **Patch encoding**: Adiciona `encoding="windows-1252"` nos build.xml
4. **Propriedades Ant**: Gera properties de dependências a partir de `dependencias.xml`
5. **Build CORE**: Compila npco_base com Ant
6. **Build WARs**: Compila cada site e gera WAR
7. **Injeção**: Copia npco_base.jar para `WEB-INF/lib` dos WARs
8. **Deploy**: Extrai WARs em `/opt/tomcat/webapps/`
9. **Tomcat**: Inicia com SingleSignOn habilitado

## Configuração

### Memória (CATALINA_OPTS)

Configurado no `docker-compose.yml`:
- `-Xms512m` - Memória inicial
- `-Xmx2048m` - Memória máxima
- `-XX:PermSize=256m` - Memória permanente inicial
- `-XX:MaxPermSize=512m` - Memória permanente máxima

### Single Sign-On

O `server.xml` inclui a valve `SingleSignOn` para permitir autenticação compartilhada entre os sites.

### Dependências

O `generate_deps_props` mapeia `dependencias.xml` para propriedades Ant:

```xml
<!-- Exemplo de dependencias.xml -->
<dependencia-arquivo id="j2ee" caminho="j2ee" nome="j2ee-1.6.jar"/>
<dependencia-pasta id="websphere_lib" caminho="websphere_lib"/>
```

Gera:
```properties
empacotamento.pasta.dependencia.j2ee=/build/deps/j2ee/j2ee-1.6.jar
empacotamento.pasta.dependencia.websphere_lib=/build/deps/websphere_lib
```

## Troubleshooting

### Erro: "Nenhum projeto CORE encontrado"
- Verifique se existe um projeto com `bin/npco_base.jar` ou `target/npco_base.jar`

### Erro: "Nenhum projeto WAR encontrado"
- Verifique se existem projetos com `WebContent/`

### Erro de compilação Java
- Verifique se os JARs de dependência estão em `docker/deps/`
- Confirme que o código é compatível com Java 7
- Verifique encoding: `sed -n 's/.*encoding="\([^"]*\)".*/\1/p' Empacotamento/Ant/build.xml`

### Build lento (bind mount Windows)
O container copia fontes para `/build/src` (FS nativo) para evitar I/O lento do bind mount. Mesmo assim, a 1ª cópia pode levar ~5-10 min.

### Container reinicia infinitamente
Verifique os logs: `docker compose logs tomcat`. O container reinicia automaticamente em caso de erro no build.

### Encoding "unmappable character"
O patch de encoding (`sed`) pode ter falhado. Verifique:
```bash
docker compose exec tomcat grep 'encoding=' /build/src/npco_base/Empacotamento/Ant/build.xml
```

## Notas Importantes

- O bind mount `../:/app/src` é **read-write** (necessário para Eclipse)
- Fontes são copiadas para `/build/src` (FS nativo) antes do build
- Logs são salvos em `/opt/tomcat/logs` e `/tmp/entrypoint.log`
- O ambiente é agnóstico - funciona com qualquer branch do Git
- Java encoding: `windows-1252` (patch automático nos build.xml)

## Testes Realizados

### npco (Principal)
- ✅ Build completo (CORE + WAR)
- ✅ Deploy no Tomcat
- ✅ Login mock funcional (I919852/cambio11)
- ✅ Página inicial carrega corretamente

### npco_analise
- ✅ Build e deploy
- ✅ Mock login funcional (BASIC auth: I919852/cambio11)
- ⚠️ Agent-browser: Erro `ERR_INVALID_AUTH_CREDENTIALS` (limitação do browser, não do container)
- ✅ curl com credenciais funciona perfeitamente

## Status VPN / Endpoints TU

| Endpoint | Status | Nota |
|----------|--------|------|
| FWOP (10.193.103.17) | ❌ Inacessível | VPN não conectada ou endpoint off |
| CWS (10.193.93.48:3130) | ❌ Inacessível | VPN não conectada ou endpoint off |
| FileNet (ecmweb...) | ❌ Inacessível | VPN não conectada ou endpoint off |
| WSDE (10.192.60.133:9081) | ❌ Inacessível | VPN não conectada ou endpoint off |

**Limitação conhecida:** Docker Desktop Windows roda containers numa Linux VM (WSL2). Mesmo com VPN conectada no host Windows, o container **não herda** a rede do host. `network_mode: host` também não funciona porque a VM tem sua própria stack de rede.

**Workaround:** Usar config TU em `conf/application-tu.properties` com IPs mockados ou aguardar VPN ativa para testes reais.

### Credenciais Mock (login-mock.xml)
```xml
<userList userName="I919852" userPassword="cambio11">
  <userGroups groupName="NPCO0001" />
  <userGroups groupName="NPCO0002" />
  <!-- ... mais grupos ... -->
</userList>
```

## Projetos Ignorados

| Projeto | Motivo |
|---------|--------|
| `npco_gestores` | 29 erros de compilação — pacote `br.com.bradesco.envio.*` ausente (problema do projeto, não do Docker) |
| `npco-lib-01-npco-base` | Pasta de dependências |
| `*-lib-*` | Pastas de dependências genéricas |
