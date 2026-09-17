# Menu / Monitor de Contratos — 17/09/2026

Checkpoint anterior: `05aaa30` (startup estavel Java 7 e JAAS isolado).

## Causa do stack trace

O log das 15:15 mostra `MenuActionPhaseListener.beforePhase` chamando
`MonitorContratosBean.iniciarPagina`, que consulta a personalizacao de colunas.
O DataSource falhava antes de conectar:

```
Cannot load JDBC driver class 'oracle.jdbc.OracleDriver'
UnsupportedClassVersionError: oracle/jdbc/OracleDriver : Unsupported major.minor version 52.0
```

O `ojdbc8.jar` exige Java 8. O runtime Java 7 e necessario para a biblioteca AWB
legada atualmente utilizada. Foi substituido na imagem por
`com.oracle.database.jdbc:ojdbc6:11.2.0.4`, publicado pela Oracle como compativel
com JDK 6/7/8. O download usa HTTPS e checksum fixo do Maven Central.
O antigo arquivo local nao e mais copiado para a imagem.

`checks/JdbcDriverCheck.java` verifica, durante o build, carga, instanciacao e
reconhecimento da URL Oracle Thin usando o proprio Java da imagem. Isso detecta
incompatibilidade de bytecode antes de iniciar o Tomcat; nao simula banco.

Referencia: https://repo.maven.apache.org/maven2/com/oracle/database/jdbc/ojdbc6/11.2.0.4/ojdbc6-11.2.0.4.pom

## Renderer do comando de busca

Na AWB-jsf-components-br-3.0.37, a tag `brCommandSearch` solicita
`HtmlCommandSearchBradesco / javax.faces.Button`, enquanto o faces-config registra
o renderer original com tipo `HtmlCommandSearchRendererBradesco`.
`conf/faces-docker-legacy.xml` registra o alias para a mesma classe original,
sem substituir componentes ou editar JARs externos. O bootstrap inclui esse
arquivo na lista JSF de cada copia de deploy de forma idempotente.

## Validacao

- Commit do checkpoint criado antes das novas alteracoes.
- `docker compose down` + `docker compose up -d --build` executados.
- Build: `Oracle JDBC carregado: 11.2 em Java 1.7.0_352`.
- Healthcheck dos dois WARs aprovado; container `healthy`, zero reinicios.
- Navegador: login mock, Operacionalizacao, Monitor de Contratos; formulario e
  filtros renderizados, incluindo seis elementos `.brCommandSearchButton`.
- Apos essa navegacao, sem `SEVERE`, `UnsupportedClassVersionError`,
  `Cannot load JDBC driver`, `SQLException` ou `ORA-` no log do novo container.
- Persistem warnings de procura de renderers do MyFaces/AWB. O erro grave
  `_inspectRenderer` do comando de busca nao reapareceu.
- Nao foram executadas alteracoes de contratos nem uma validacao abrangente
  de consultas/procedures do banco.

As alteracoes deste diagnostico ficam somente em docker-legacy e nas copias
geradas pelo container. As fontes NPCO continuam montadas em somente leitura.
