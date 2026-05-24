# Alianca Backend

Backend Supabase do Alianca. Este diretório concentra schema, policies, migrations e edge functions que sustentam autenticacao, onboarding do casal, tarefas compartilhadas, gamificacao e sugestoes do Cupido.

## Stack

- Supabase CLI
- Postgres com RLS
- Realtime
- Edge Functions

## Estrutura

- `supabase/config.toml`: configuracao da stack local.
- `supabase/migrations/`: schema versionado do projeto.
- `supabase/functions/cupido-suggestions/`: edge function que monta contexto do casal e pede sugestoes ao Groq.
- `package.json`: dependencia da CLI local do Supabase.

## O que existe no schema

Principais entidades do schema publico:

- `profiles`: perfil do usuario, data de nascimento, token pessoal e dados de conexao.
- `partnership_invitations`: convites entre usuarios.
- `couple_workspaces`: dados do casal, etapa do relacionamento, progresso e XP.
- `couple_memberships`: membros vinculados ao workspace.
- `user_questionnaires`: questionario individual.
- `couple_children`: filhos cadastrados no questionario conjunto.
- `couple_tasks`: tarefas do casal com dificuldade, categoria, frequencia, dias personalizados e prazo.

## Migrations relevantes

- `20260524132000_relationship_app_foundation.sql`: base do schema, auth flow, convites, tarefas e RLS inicial.
- `20260524153000_onboarding_children_realtime_refresh.sql`: nascimento, filhos, realtime, deadlines e XP por nivel.
- `20260524212000_profiles_insert_policy.sql`: permite inserir o proprio perfil no fluxo de cadastro.
- `20260524213500_profiles_select_related_invites.sql`: permite ler nome do remetente em convites relacionados.
- `20260524220000_task_frequency_and_category.sql`: adiciona categoria, frequencia e dias da semana nas tarefas.

## Rodando localmente

Instale dependencias:

```bash
npm install
```

Suba a stack local:

```bash
npx supabase start
```

Reaplique todas as migrations:

```bash
npx supabase db reset
```

Servicos locais mais usados:

- API REST: `http://127.0.0.1:54321`
- Banco Postgres: porta `54322`
- Studio: `http://127.0.0.1:54323`
- Inbucket: `http://127.0.0.1:54324`

## Edge Function do Cupido

A function `cupido-suggestions`:

- recebe o `workspaceId`
- valida o usuario autenticado
- monta o contexto do casal com perfis, questionarios, filhos e tarefas
- chama o Groq no server side
- devolve 5 sugestoes ja no formato de tarefa

### Rodar localmente

```bash
npx supabase functions serve cupido-suggestions --no-verify-jwt
```

### Deploy

```bash
npx supabase functions deploy cupido-suggestions
```

### Secret necessario

Configure o secret do Groq no projeto antes de usar a function em producao:

```bash
npx supabase secrets set GROQ_API_KEY=... 
```

Tambem e esperado que o ambiente do Supabase exponha `SUPABASE_URL`, `SUPABASE_ANON_KEY` e `SUPABASE_SERVICE_ROLE_KEY` para a function.

## Validacao util

Aplicar schema do zero:

```bash
npx supabase db reset
```

Servir a edge function localmente:

```bash
npx supabase functions serve cupido-suggestions --no-verify-jwt
```

## Observacoes

- O projeto esta usando RLS em tabelas principais.
- O frontend depende de enums e campos do schema atual; alteracoes em `couple_tasks` e `profiles` normalmente exigem ajuste no app.
- O Cupido e server-side por design para nao expor a chave do provedor no cliente.

## Referencias

- Supabase CLI: https://supabase.com/docs/guides/cli
- Supabase Database: https://supabase.com/docs/guides/database
- Supabase Edge Functions: https://supabase.com/docs/guides/functions
- Supabase Realtime: https://supabase.com/docs/guides/realtime
- Groq Docs: https://console.groq.com/docs/overview