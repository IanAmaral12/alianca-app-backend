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

function jsonResponse(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { headers: corsHeaders, status });
}

function sanitizeSuggestion(rawSuggestion: Suggestion): Suggestion {
  const dueAt = rawSuggestion.due_at && !Number.isNaN(Date.parse(rawSuggestion.due_at))
    ? new Date(rawSuggestion.due_at).toISOString()
    : null;

  const customWeekdays = rawSuggestion.frequency === 'custom_weekdays'
    ? Array.from(new Set((rawSuggestion.custom_weekdays ?? []).filter((weekday): weekday is Weekday =>
      weekdayValues.includes(weekday as Weekday),
    )))
    : null;

  return {
    category: categoryValues.includes(rawSuggestion.category) ? rawSuggestion.category : 'routine',
    custom_weekdays: rawSuggestion.frequency === 'custom_weekdays' ? customWeekdays : null,
    description: rawSuggestion.description?.trim() || null,
    difficulty: difficultyValues.includes(rawSuggestion.difficulty) ? rawSuggestion.difficulty : 'easy',
    due_at: dueAt,
    frequency: frequencyValues.includes(rawSuggestion.frequency) ? rawSuggestion.frequency : 'one_time',
    title: rawSuggestion.title.trim(),
  };
}

Deno.serve(async (request) => {
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

  const contextPayload = {
    children: childrenResult.data ?? [],
    members,
    tasks: tasksResult.data ?? [],
    today: new Date().toISOString(),
    workspace: workspaceResult.data,
  };

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
          content:
            'Voce e o Cupido, um assistente de relacionamento para um app de casais. Gere exatamente 5 sugestoes de tarefas em portugues do Brasil, concretas, afetivas e realistas, usando apenas o contexto fornecido. Evite repetir tarefas ja frequentes no historico. Use categorias e frequencias adequadas. Quando frequency for custom_weekdays, informe custom_weekdays com pelo menos um dia. Quando nao for custom_weekdays, informe custom_weekdays como null. Use due_at em ISO 8601 apenas quando fizer sentido temporal claro; caso contrario, use null. Responda apenas com JSON valido seguindo o schema.',
        },
        {
          role: 'user',
          content: JSON.stringify(contextPayload),
        },
      ],
      response_format: {
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
      },
    }),
  });

  if (!groqResponse.ok) {
    const groqErrorText = await groqResponse.text();
    return jsonResponse(502, { error: `Groq request failed: ${groqErrorText}` });
  }

  const groqPayload = await groqResponse.json();
  const rawContent = groqPayload?.choices?.[0]?.message?.content;

  if (typeof rawContent !== 'string') {
    return jsonResponse(502, { error: 'Groq returned an empty response.' });
  }

  let parsedContent: { suggestions: Suggestion[] };

  try {
    parsedContent = JSON.parse(rawContent);
  } catch {
    return jsonResponse(502, { error: 'Groq returned invalid JSON.' });
  }

  const suggestions = (parsedContent.suggestions ?? [])
    .map(sanitizeSuggestion)
    .filter((suggestion) => suggestion.title);

  if (suggestions.length !== 5) {
    return jsonResponse(502, { error: 'Groq did not return exactly 5 valid suggestions.' });
  }

  return jsonResponse(200, { suggestions });
});