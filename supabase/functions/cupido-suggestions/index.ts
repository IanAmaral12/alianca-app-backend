import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Origin': '*',
  'Content-Type': 'application/json',
};

const difficultyValues = ['easy', 'medium', 'hard'] as const;
const frequencyValues = ['daily', 'weekly', 'monthly', 'one_time', 'custom_weekdays'] as const;
const categoryValues = ['leisure', 'sport', 'commitment', 'children', 'routine', 'romantic_date'] as const;
const weekdayValues = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'] as const;

type TaskDifficulty = (typeof difficultyValues)[number];
type TaskFrequency = (typeof frequencyValues)[number];
type TaskCategory = (typeof categoryValues)[number];
type Weekday = (typeof weekdayValues)[number];

type Suggestion = {
  category: TaskCategory;
  custom_weekdays: Weekday[] | null;
  description: string | null;
  difficulty: TaskDifficulty;
  due_at: string | null;
  frequency: TaskFrequency;
  title: string;
};

type ContextPayload = {
  children: Array<Record<string, unknown>>;
  members: Array<Record<string, unknown>>;
  tasks: Array<Record<string, unknown>>;
  today: string;
  workspace: Record<string, unknown> | null;
};

type RawSuggestion = Partial<Record<keyof Suggestion, unknown>>;

function jsonResponse(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { headers: corsHeaders, status });
}

function normalizeText(value: unknown) {
  return typeof value === 'string' ? value.trim() : '';
}

function sanitizeSuggestion(rawSuggestion: RawSuggestion): Suggestion | null {
  const title = normalizeText(rawSuggestion.title);

  if (!title) {
    return null;
  }

  const rawDueAt = typeof rawSuggestion.due_at === 'string' ? rawSuggestion.due_at : null;
  const dueAt = rawDueAt && !Number.isNaN(Date.parse(rawDueAt))
    ? new Date(rawDueAt).toISOString()
    : null;

  const frequency = frequencyValues.includes(rawSuggestion.frequency as TaskFrequency)
    ? rawSuggestion.frequency as TaskFrequency
    : 'one_time';

  const rawWeekdays = Array.isArray(rawSuggestion.custom_weekdays) ? rawSuggestion.custom_weekdays : [];
  const customWeekdays = frequency === 'custom_weekdays'
    ? Array.from(new Set(rawWeekdays.filter((weekday): weekday is Weekday =>
      typeof weekday === 'string' && weekdayValues.includes(weekday as Weekday),
    )))
    : null;

  const description = typeof rawSuggestion.description === 'string'
    ? rawSuggestion.description.trim() || null
    : null;

  return {
    category: categoryValues.includes(rawSuggestion.category as TaskCategory) ? rawSuggestion.category as TaskCategory : 'routine',
    custom_weekdays: frequency === 'custom_weekdays' ? (customWeekdays.length > 0 ? customWeekdays : ['monday']) : null,
    description,
    difficulty: difficultyValues.includes(rawSuggestion.difficulty as TaskDifficulty) ? rawSuggestion.difficulty as TaskDifficulty : 'easy',
    due_at: dueAt,
    frequency,
    title,
  };
}

function safeJsonParse(value: string) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function buildSystemPrompt(jsonMode = false) {
  return [
    'Voce e o Cupido, um assistente de relacionamento para um app de casais.',
    'Gere exatamente 5 sugestoes de tarefas em portugues do Brasil, concretas, afetivas e realistas, usando apenas o contexto fornecido.',
    'Evite repetir tarefas ja frequentes no historico.',
    'Use categorias e frequencias adequadas.',
    'Quando frequency for custom_weekdays, informe custom_weekdays com pelo menos um dia.',
    'Quando nao for custom_weekdays, informe custom_weekdays como null.',
    'Use due_at em ISO 8601 apenas quando fizer sentido temporal claro; caso contrario, use null.',
    jsonMode
      ? 'Responda apenas com um objeto JSON valido com a chave suggestions.'
      : 'Responda apenas com JSON valido seguindo o schema.',
  ].join(' ');
}

function buildJsonSchemaResponseFormat() {
  return {
    type: 'json_schema',
    json_schema: {
      name: 'cupido_task_suggestions',
      strict: true,
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          suggestions: {
            type: 'array',
            minItems: 5,
            maxItems: 5,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                title: { type: 'string' },
                description: { anyOf: [{ type: 'string' }, { type: 'null' }] },
                difficulty: { type: 'string', enum: [...difficultyValues] },
                frequency: { type: 'string', enum: [...frequencyValues] },
                custom_weekdays: {
                  anyOf: [
                    {
                      type: 'array',
                      items: { type: 'string', enum: [...weekdayValues] },
                      minItems: 1,
                      uniqueItems: true,
                    },
                    { type: 'null' },
                  ],
                },
                category: { type: 'string', enum: [...categoryValues] },
                due_at: { anyOf: [{ type: 'string' }, { type: 'null' }] },
              },
              required: ['title', 'description', 'difficulty', 'frequency', 'custom_weekdays', 'category', 'due_at'],
            },
          },
        },
        required: ['suggestions'],
      },
    },
  };
}

async function requestGroqSuggestions(groqApiKey: string, contextPayload: ContextPayload, mode: 'strict' | 'json_object') {
  const groqResponse = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${groqApiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'openai/gpt-oss-20b',
      temperature: 0.7,
      messages: [
        {
          role: 'system',
          content: buildSystemPrompt(mode === 'json_object'),
        },
        {
          role: 'user',
          content: JSON.stringify(contextPayload),
        },
      ],
      response_format: mode === 'strict' ? buildJsonSchemaResponseFormat() : { type: 'json_object' },
    }),
  });

  const responseText = await groqResponse.text();

  if (!groqResponse.ok) {
    throw new Error(`Groq ${mode} failed: ${responseText}`);
  }

  const groqPayload = safeJsonParse(responseText);
  const rawContent = groqPayload?.choices?.[0]?.message?.content;

  if (typeof rawContent !== 'string') {
    throw new Error(`Groq ${mode} returned empty content.`);
  }

  const parsedContent = safeJsonParse(rawContent);

  if (!parsedContent || !Array.isArray(parsedContent.suggestions)) {
    throw new Error(`Groq ${mode} returned invalid suggestion payload.`);
  }

  return parsedContent.suggestions as RawSuggestion[];
}

function buildFallbackSuggestions(contextPayload: ContextPayload) {
  const memberNames = contextPayload.members
    .map((member) => typeof member.full_name === 'string' ? member.full_name.trim() : '')
    .filter(Boolean);
  const coupleLabel = memberNames.length > 0 ? memberNames.join(' e ') : 'voces dois';
  const hasChildren = contextPayload.children.length > 0;

  const fallbackSuggestions: Suggestion[] = [
    {
      category: 'romantic_date',
      custom_weekdays: null,
      description: `Reservem um momento sem telas para conversar sobre a semana, celebrar uma conquista e alinhar o que ${coupleLabel} querem viver nos proximos dias.`,
      difficulty: 'easy',
      due_at: null,
      frequency: 'weekly',
      title: 'Encontro de alinhamento do casal',
    },
    {
      category: 'routine',
      custom_weekdays: ['monday', 'thursday'],
      description: 'Criem um checkpoint curto para revisar agenda, tarefas da casa e necessidades emocionais antes que a semana acelere.',
      difficulty: 'easy',
      due_at: null,
      frequency: 'custom_weekdays',
      title: 'Checkpoint rapido da semana',
    },
    {
      category: 'leisure',
      custom_weekdays: null,
      description: 'Escolham uma experiencia leve para sair da rotina juntos, como um cafe diferente, filme tematico ou passeio ao ar livre.',
      difficulty: 'medium',
      due_at: null,
      frequency: 'monthly',
      title: 'Programar um momento leve a dois',
    },
    {
      category: hasChildren ? 'children' : 'commitment',
      custom_weekdays: null,
      description: hasChildren
        ? 'Planejem uma atividade simples com os filhos que seja prazerosa para todos e reduza a sensacao de rotina automatica.'
        : 'Definam um pequeno compromisso concreto que melhore a organizacao da semana e alivie a carga mental do casal.',
      difficulty: 'medium',
      due_at: null,
      frequency: 'one_time',
      title: hasChildren ? 'Criar um momento especial em familia' : 'Resolver um ponto pratico pendente',
    },
    {
      category: 'sport',
      custom_weekdays: null,
      description: 'Escolham uma atividade corporal simples para fazerem juntos, com foco em energia, humor e parceria, sem meta de performance.',
      difficulty: 'hard',
      due_at: null,
      frequency: 'weekly',
      title: 'Movimento juntos para renovar a energia',
    },
  ];

  return fallbackSuggestions;
}

function finalizeSuggestions(rawSuggestions: RawSuggestion[], contextPayload: ContextPayload) {
  const normalized = rawSuggestions
    .map(sanitizeSuggestion)
    .filter((suggestion): suggestion is Suggestion => Boolean(suggestion?.title))
    .slice(0, 5);

  if (normalized.length === 5) {
    return normalized;
  }

  const fallbackSuggestions = buildFallbackSuggestions(contextPayload);
  const existingTitles = new Set(normalized.map((suggestion) => suggestion.title.toLowerCase()));

  for (const fallbackSuggestion of fallbackSuggestions) {
    if (normalized.length >= 5) {
      break;
    }

    if (!existingTitles.has(fallbackSuggestion.title.toLowerCase())) {
      normalized.push(fallbackSuggestion);
      existingTitles.add(fallbackSuggestion.title.toLowerCase());
    }
  }

  return normalized.slice(0, 5);
}

Deno.serve(async (request) => {
  try {
    if (request.method === 'OPTIONS') {
      return new Response('ok', { headers: corsHeaders });
    }

    if (request.method !== 'POST') {
      return jsonResponse(405, { error: 'Method not allowed' });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const groqApiKey = Deno.env.get('GROQ_API_KEY');
    const authHeader = request.headers.get('Authorization');

    if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceRoleKey || !groqApiKey) {
      return jsonResponse(500, { error: 'Missing required server configuration.' });
    }

    if (!authHeader) {
      return jsonResponse(401, { error: 'Missing authorization header.' });
    }

    let workspaceId = '';

    try {
      const requestBody = await request.json();
      workspaceId = typeof requestBody.workspaceId === 'string' ? requestBody.workspaceId.trim() : '';
    } catch {
      return jsonResponse(400, { error: 'Invalid request body.' });
    }

    if (!workspaceId) {
      return jsonResponse(400, { error: 'workspaceId is required.' });
    }

    const authClient = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    });

    const serviceClient = createClient(supabaseUrl, supabaseServiceRoleKey, {
      auth: { persistSession: false },
    });

    const {
      data: { user },
      error: userError,
    } = await authClient.auth.getUser();

    if (userError || !user) {
      return jsonResponse(401, { error: 'Unable to resolve authenticated user.' });
    }

    const { data: membership, error: membershipError } = await serviceClient
      .from('couple_memberships')
      .select('workspace_id')
      .eq('user_id', user.id)
      .eq('workspace_id', workspaceId)
      .maybeSingle();

    if (membershipError) {
      return jsonResponse(500, { error: membershipError.message });
    }

    if (!membership?.workspace_id) {
      return jsonResponse(403, { error: 'Workspace access denied.' });
    }

    const [workspaceResult, membershipsResult, tasksResult, childrenResult] = await Promise.all([
      serviceClient.from('couple_workspaces').select('*').eq('id', workspaceId).single(),
      serviceClient.from('couple_memberships').select('user_id').eq('workspace_id', workspaceId),
      serviceClient
        .from('couple_tasks')
        .select('title, description, difficulty, category, frequency, custom_weekdays, completed, completed_at, due_at, points, created_at')
        .eq('workspace_id', workspaceId)
        .order('created_at', { ascending: false }),
      serviceClient
        .from('couple_children')
        .select('name, gender, birth_date, sort_order')
        .eq('workspace_id', workspaceId)
        .order('sort_order', { ascending: true }),
    ]);

    if (workspaceResult.error) {
      return jsonResponse(500, { error: workspaceResult.error.message });
    }

    if (membershipsResult.error) {
      return jsonResponse(500, { error: membershipsResult.error.message });
    }

    if (tasksResult.error) {
      return jsonResponse(500, { error: tasksResult.error.message });
    }

    if (childrenResult.error) {
      return jsonResponse(500, { error: childrenResult.error.message });
    }

    const memberIds = (membershipsResult.data ?? []).map((membershipRow) => membershipRow.user_id);

    const [profilesResult, questionnairesResult] = await Promise.all([
      serviceClient
        .from('profiles')
        .select('id, full_name, birth_date')
        .in('id', memberIds),
      serviceClient
        .from('user_questionnaires')
        .select('user_id, partner_admired_trait, self_trait_partner_admires, relationship_definition, completed_at')
        .in('user_id', memberIds),
    ]);

    if (profilesResult.error) {
      return jsonResponse(500, { error: profilesResult.error.message });
    }

    if (questionnairesResult.error) {
      return jsonResponse(500, { error: questionnairesResult.error.message });
    }

    const questionnaireByUserId = new Map(
      (questionnairesResult.data ?? []).map((questionnaire) => [questionnaire.user_id, questionnaire]),
    );

    const members = (profilesResult.data ?? []).map((profile) => ({
      birth_date: profile.birth_date,
      full_name: profile.full_name,
      questionnaire: questionnaireByUserId.get(profile.id) ?? null,
    }));

    const contextPayload: ContextPayload = {
      children: childrenResult.data ?? [],
      members,
      tasks: tasksResult.data ?? [],
      today: new Date().toISOString(),
      workspace: workspaceResult.data,
    };

    let rawSuggestions: RawSuggestion[] = [];
    let provider = 'groq-strict';
    let warning: string | null = null;

    try {
      rawSuggestions = await requestGroqSuggestions(groqApiKey, contextPayload, 'strict');
    } catch (strictError) {
      console.error('Cupido strict mode failed', strictError);

      try {
        rawSuggestions = await requestGroqSuggestions(groqApiKey, contextPayload, 'json_object');
        provider = 'groq-json-object';
        warning = 'Structured output strict falhou; usando fallback JSON.';
      } catch (jsonModeError) {
        console.error('Cupido json_object mode failed', jsonModeError);
        rawSuggestions = buildFallbackSuggestions(contextPayload);
        provider = 'fallback';
        warning = 'Groq indisponivel ou respondeu fora do esperado; usando sugestoes de fallback.';
      }
    }

    const suggestions = finalizeSuggestions(rawSuggestions, contextPayload);

    if (suggestions.length !== 5) {
      console.error('Cupido could not assemble 5 suggestions', { suggestionsLength: suggestions.length });
      return jsonResponse(500, { error: 'Nao foi possivel montar sugestoes suficientes.' });
    }

    return jsonResponse(200, { provider, suggestions, warning });
  } catch (error) {
    console.error('Cupido unexpected error', error);
    const message = error instanceof Error ? error.message : 'Unexpected edge function error.';
    return jsonResponse(500, { error: message });
  }
});