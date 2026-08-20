#!/usr/bin/env bash
# Inicializa a estrutura de specs/tasks (workflow sem GitHub Issues) na raiz
# do repo atual: cria as pastas, os templates e os scripts bin/next-task e
# bin/board prontos para uso.
#
# Uso:
#   ./init-workflow.sh
#
# Idempotente: pode rodar de novo sem sobrescrever arquivos já existentes.

set -euo pipefail

if [ ! -d .git ]; then
  echo "Aviso: não parece ser a raiz de um repo git (sem .git aqui)." >&2
  read -rp "Continuar mesmo assim? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

mkdir -p specs
mkdir -p tasks/ready tasks/doing tasks/review tasks/done
mkdir -p templates
mkdir -p bin

write_if_missing() {
  local path="$1"
  if [ -e "$path" ]; then
    echo "== já existe, pulando: $path"
    return
  fi
  cat > "$path"
  echo "== criado: $path"
}

# --- templates/task.md ---
write_if_missing templates/task.md <<'EOF'
# 000 - Título curto da task

Spec: specs/000-nome-da-spec.md

## Contexto
Uma ou duas frases sobre por que essa task existe.

## Critério de pronto
- [ ] ...
- [ ] ...
- [ ] Testes passando

## Notas
(opcional — decisões, links, observações para quem/o que for implementar)
EOF

# --- templates/spec.md ---
write_if_missing templates/spec.md <<'EOF'
# 000 - Nome da Spec

## Contexto
O que é isso e por que está sendo feito.

## Critérios de aceite
- ...
- ...

## Contratos de API / interfaces
(endpoints, assinaturas de função, schemas de dados, eventos)

## Edge cases
- ...

## Fora de escopo
- ...
EOF

# --- bin/next-task ---
write_if_missing bin/next-task <<'EOF'
#!/usr/bin/env bash
# Pega a próxima task em tasks/ready/, cria uma git worktree isolada
# e dispara o Claude Code em modo headless para implementá-la.
#
# Uso:
#   bin/next-task                # pega a primeira task disponível
#   bin/next-task 023-billing.md # pega uma task específica

set -euo pipefail

TASKS_DIR="tasks"
READY_DIR="$TASKS_DIR/ready"
DOING_DIR="$TASKS_DIR/doing"

if [ ! -d "$READY_DIR" ]; then
  echo "Diretório $READY_DIR não encontrado. Rode este script na raiz do repo." >&2
  exit 1
fi

task_file="${1:-$(ls "$READY_DIR" 2>/dev/null | head -1)}"

if [ -z "$task_file" ]; then
  echo "Nenhuma task pendente em $READY_DIR."
  exit 0
fi

task_path="$READY_DIR/$task_file"
if [ ! -f "$task_path" ]; then
  echo "Task '$task_file' não encontrada em $READY_DIR." >&2
  exit 1
fi

task_id="${task_file%%-*}"
branch="task-${task_id}"
repo_name="$(basename "$(git rev-parse --show-toplevel)")"
worktree_dir="../${repo_name}-${task_id}"

spec_ref="$(grep -m1 '^Spec:' "$task_path" | sed 's/^Spec:[[:space:]]*//' || true)"

echo "==> Task: $task_file"
[ -n "$spec_ref" ] && echo "==> Spec:  $spec_ref"
echo "==> Branch: $branch"
echo "==> Worktree: $worktree_dir"

mv "$task_path" "$DOING_DIR/"

git worktree add "$worktree_dir" -b "$branch"

prompt="Implemente a task descrita em ${TASKS_DIR}/doing/${task_file}."
if [ -n "$spec_ref" ]; then
  prompt="${prompt} Siga rigorosamente a especificação em ${spec_ref}."
fi
prompt="${prompt} Rode os testes existentes antes de finalizar. Ao concluir, abra um PR e mova o arquivo de ${TASKS_DIR}/doing/ para ${TASKS_DIR}/review/."

echo "==> Disparando Claude Code (headless) em ${worktree_dir}..."
(cd "$worktree_dir" && claude -p "$prompt")
EOF
chmod +x bin/next-task 2>/dev/null || true

# --- bin/board ---
write_if_missing bin/board <<'EOF'
#!/usr/bin/env bash
# Mostra um resumo do quadro de tasks (ready/doing/review/done) de todos
# os projetos dentro de um diretório pai.
#
# Uso:
#   bin/board                    # usa ~/projects como diretório pai
#   bin/board ~/meus-projetos    # usa outro diretório pai

set -euo pipefail

PROJECTS_DIR="${1:-$HOME/projects}"

if [ ! -d "$PROJECTS_DIR" ]; then
  echo "Diretório '$PROJECTS_DIR' não encontrado." >&2
  exit 1
fi

printf "%-30s %6s %6s %6s %6s\n" "PROJETO" "READY" "DOING" "REVIEW" "DONE"
printf "%-30s %6s %6s %6s %6s\n" "-------" "-----" "-----" "------" "----"

for d in "$PROJECTS_DIR"/*/; do
  name="$(basename "$d")"
  [ -d "${d}tasks" ] || continue

  ready="$(ls "${d}tasks/ready" 2>/dev/null | wc -l | tr -d ' ')"
  doing="$(ls "${d}tasks/doing" 2>/dev/null | wc -l | tr -d ' ')"
  review="$(ls "${d}tasks/review" 2>/dev/null | wc -l | tr -d ' ')"
  done_c="$(ls "${d}tasks/done" 2>/dev/null | wc -l | tr -d ' ')"

  printf "%-30s %6s %6s %6s %6s\n" "$name" "$ready" "$doing" "$review" "$done_c"
done
EOF
chmod +x bin/board 2>/dev/null || true

# .gitkeep para as pastas de tasks (senão o git não versiona pasta vazia)
for d in ready doing review done; do
  touch "tasks/$d/.gitkeep"
done

chmod +x bin/next-task bin/board

echo
echo "Estrutura inicializada:"
echo "  specs/            (vazio, pronto para specs)"
echo "  tasks/ready|doing|review|done"
echo "  templates/task.md, templates/spec.md"
echo "  bin/next-task, bin/board (executáveis)"
echo
echo "Próximo passo: copie templates/task.md para tasks/ready/001-nome.md e comece."