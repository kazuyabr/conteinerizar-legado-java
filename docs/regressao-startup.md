# Diagnostico do startup (17/09/2026)

## Evidencias e referencias consultadas

- `origin/main` / primeiro commit `318a66e`: Azul Java 7, Tomcat 7,
  Ant 1.9.16, PermGen 256/512 MB e adaptador EL no `WEB-INF/lib`.
- Alteracoes locais posteriores trocaram Java 7 por Java 8 e removeram
  os limites de PermGen. O adaptador EL ainda usava o executavel do Java 7.
- `localhost.2026-09-17.log`, boot das 14:06: falha no inicializador de
  `BradescoIntranetLdapLMImpl`, causada por `NoSuchFieldException: addressCache`.
  `javap -private java.net.InetAddress` confirma que o campo existe no runtime
  Java 7 original e nao existe no Java 8 instalado no container da regressao.
- Eclipse em `Documents/WorkspaceNPCO`: `.classpath` declara JavaSE-1.7,
  Tomcat 7, `lib_IBM_was_85`, PDC em `C:/MCNL-CORPORATIVO-NEGOCIO`
  e JSON em `C:/NPCO-BASE-NEG-V1`. O deployment assembly publica `WebContent`
  na raiz, `JavaSource` em `WEB-INF/classes` e a dependencia `npco_base` em lib.
- `.metadata/.plugins/org.eclipse.wst.server.core/servers.xml`: deploy WTP
  em `wtpwebapps`. `Servers/.../catalina.properties` usa loaders padrao;
  nao exige promover OpenWebBeans para o loader comum do Tomcat.
- `C:/Ambiente Java` possui instalacoes Java 8 antigas; isso nao equivale
  ao Java 8 atualizado da imagem que apresentou a falha de reflexao.
- `C:/suportedbdc_config/intranet/npco/application.properties`: configuracao
  externa, login mock e salt de oito caracteres. O equivalente do container
  e `/conf/intranet/<app>/application.properties`, alimentado pelo template local.
- `C:/ibm_was_8_5` e `C:/suportedbdc_lib`: referencias de bibliotecas.
  As dependencias do build continuam sendo lidas de `../docker/deps` e copiadas
  para `/build/deps`. `C:/MININT` contem arquivos de provisionamento Windows,
  nao configuracao do Tomcat.

## Correcoes

1. Runtime Java 7 original fixado por digest, com PermGen restaurado.
2. Adaptador `org.apache.webbeans.el.WebBeansELResolver` compilado com o JDK
   ativo para Java 7 e instalado somente nos WARs. Falha de compilacao interrompe
   o bootstrap. Os modulos LDAP originais nao sao substituidos por mocks de classe.
3. `bash -n` e normalizacao LF durante o build da imagem.
4. Fontes externas montadas somente para leitura. Adaptacoes sao feitas nas
   copias internas em `/build` e `/opt/tomcat/webapps`.
5. Realm JAAS usa o nome e o arquivo de configuracao de cada WAR, evitando
   que o registro global de um listener substitua o registro da outra aplicacao.
6. `conf/login-mock.xml` internaliza a conta local de referencia para WARs que
   declaram o modulo mock mas nao empacotam seu arquivo de usuarios.
7. Remocao da referencia ao XML opcional de managed beans somente quando ausente
   e correcao da taglib para `WEB-INF/classes/META-INF/components.taglib.xml`
   quando presente, removendo a referencia opcional quando ausente.
8. Healthcheck autentica e exige pagina JSF renderizada nos dois contextos.

## Verificacao operacional

```powershell
docker compose down
docker compose up -d --build
docker exec legacy-tomcat /healthcheck.sh
docker inspect --format '{{.State.Health.Status}}' legacy-tomcat
docker logs --since 10m legacy-tomcat
```

Consultar `docker exec legacy-tomcat date -Iseconds` antes de escolher o arquivo
`localhost.AAAA-MM-DD.log`. Logs em volumes persistentes incluem boots anteriores.
O calculo do hash no bind mount Windows pode levar minutos; nao apagar caches nem
reiniciar durante esse calculo. Build de imagem e compilacao Ant sao etapas distintas.

O healthcheck cobre startup, autenticacao mock e renderizacao JSF. Integracoes TU,
Oracle e operacoes de negocio precisam de validacao propria com a rede e os dados
apropriados; nao sao exercitadas pelo healthcheck.

## Resultado verificado

Boot final em 17/09/2026, adaptador gerado as 14:51:46 UTC:

- `legacy-tomcat`: `healthy`, zero reinicios.
- Os dois containers CDI validaram todos os pontos de injecao.
- Tomcat concluiu startup em 52.153 ms (apos a verificacao de cache).
- HTTP autenticado pelo host Windows: `npco=200`, `npco_analise=200`.
- `/healthcheck.sh` terminou com codigo zero, verificando texto da pagina e
  `javax.faces.ViewState` dos dois contextos.
- Nenhuma ocorrencia de `SEVERE` ou `Exception` no stdout/stderr desse container
  ate a verificacao final. Persistem avisos legados de renderers/MyFaces.
- `/app/src` confirmado com `rw=false`.
- Imagem reconstruida com `docker compose down` e `docker compose up -d --build`;
  os WARs Java 7 do build Ant anterior foram reutilizados pelo cache neste boot.
