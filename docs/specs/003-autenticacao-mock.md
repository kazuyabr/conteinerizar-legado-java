# Spec 003 - Autenticacao Mock Local+TU

## Objetivo

Garantir que o ambiente Docker consiga autenticar Local+TU sem depender de
pastas externas, branch especifica ou da ordem dos arquivos do projeto.

## Regra de precedencia

Quando um WAR usa `BradescoIntranetMockLMImpl`, o Docker deve resolver o
`login-mock.xml` nesta ordem:

1. `WEB-INF/classes/login-mock.xml` do WAR, se existir.
2. `WEB-INF/login-mock.xml` do WAR, copiado para `WEB-INF/classes/login-mock.xml`.
3. `conf/login-mock.xml` do Docker como fallback minimo.

## Requisitos

- O Docker nao pode depender de `C:/suportedbdc*` para o mock de login.
- O Docker deve registrar a origem efetiva do arquivo usado por WAR.
- Se o arquivo existir mas nao for valido, o deploy do WAR deve falhar.
- O fallback do Docker deve manter o ambiente operante quando a branch nao
  empacotar `login-mock.xml`.

## Validacao

- `npco` e `npco_analise` devem autenticar com a conta mock esperada.
- O healthcheck deve usar a conta disponivel na precedencia efetiva.
- A troca de branch nao pode alterar silenciosamente o conjunto de usuarios.

## Observacoes

- O fallback em `conf/login-mock.xml` e propositalmente minimo.
- O arquivo completo de cada projeto continua sendo preferido quando existe.
