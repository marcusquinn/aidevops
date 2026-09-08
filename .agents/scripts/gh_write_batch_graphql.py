"""Pure GraphQL compilation for managed GitHub write batches."""

from __future__ import annotations

from typing import Any, Callable, NamedTuple

BodyLoader = Callable[[dict[str, Any]], str]


class MutationBuild(NamedTuple):
    """Mutable containers shared while compiling one GraphQL mutation."""

    label_ids: dict[str, str]
    declarations: list[str]
    variables: dict[str, Any]
    body_loader: BodyLoader


def preflight_query(prepared: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    declarations = ["$owner:String!", "$name:String!"]
    fields: list[str] = ["viewerPermission"]
    owner, name = prepared["repository"].split("/", 1)
    variables: dict[str, Any] = {"owner": owner, "name": name}
    labels = sorted({label for op in prepared["operations"] for label in op.get("labels", [])})
    for index, operation in enumerate(prepared["operations"]):
        declarations.append(f"$number{index}:Int!")
        variables[f"number{index}"] = operation["number"]
        comments = ""
        if prepared.get("recovery_of") and operation["kind"].endswith("_comment"):
            comments = " comments(last:100){nodes{body} pageInfo{hasPreviousPage}}"
        fields.append(
            f't{index}:issueOrPullRequest(number:$number{index}){{__typename ... on Issue{{id number title body labels(first:100){{nodes{{id name}} pageInfo{{hasNextPage}}}}{comments}}} ... on PullRequest{{id number title body labels(first:100){{nodes{{id name}} pageInfo{{hasNextPage}}}}{comments}}}}}}}'
        )
    for index, label in enumerate(labels):
        declarations.append(f"$label{index}:String!")
        variables[f"label{index}"] = label
        fields.append(f'l{index}:label(name:$label{index}){{id name}}')
    query = f"query({','.join(declarations)}){{repository(owner:$owner,name:$name){{{' '.join(fields)}}}}}"
    return query, variables


def comment_mutation(index: int, alias: str, operation: dict[str, Any], build: MutationBuild) -> str:
    build.declarations.append(f"$body{index}:String!")
    build.variables[f"body{index}"] = build.body_loader(operation)
    return f'{alias}:addComment(input:{{subjectId:$target{index},body:$body{index},clientMutationId:$client{index}}}){{clientMutationId commentEdge{{node{{id url}}}}}}'


def edit_mutation(index: int, alias: str, operation: dict[str, Any], build: MutationBuild) -> str:
    mutation_name = "updatePullRequest" if operation["kind"] == "pr_edit" else "updateIssue"
    inputs = [f"id:$target{index}", f"clientMutationId:$client{index}"]
    for field in ("title", "body"):
        operation_key = "body_file" if field == "body" else field
        if operation_key not in operation:
            continue
        build.declarations.append(f"${field}{index}:String!")
        build.variables[f"{field}{index}"] = (
            build.body_loader(operation) if field == "body" else operation[operation_key]
        )
        inputs.append(f"{field}:${field}{index}")
    result_name = "pullRequest" if operation["kind"] == "pr_edit" else "issue"
    return f'{alias}:{mutation_name}(input:{{{",".join(inputs)}}}){{clientMutationId {result_name}{{id number}}}}'


def label_mutation(index: int, alias: str, operation: dict[str, Any], build: MutationBuild) -> str:
    build.declarations.append(f"$labels{index}:[ID!]!")
    build.variables[f"labels{index}"] = [build.label_ids[label] for label in operation["labels"]]
    mutation_name = (
        "addLabelsToLabelable" if operation["kind"].endswith("add_labels") else "removeLabelsFromLabelable"
    )
    return f'{alias}:{mutation_name}(input:{{labelableId:$target{index},labelIds:$labels{index},clientMutationId:$client{index}}}){{clientMutationId}}'


def mutation_field(index: int, alias: str, operation: dict[str, Any], build: MutationBuild) -> str:
    kind = operation["kind"]
    if kind.endswith("_comment"):
        return comment_mutation(index, alias, operation, build)
    if kind.endswith("_edit"):
        return edit_mutation(index, alias, operation, build)
    return label_mutation(index, alias, operation, build)


def mutation(
    prepared: dict[str, Any],
    label_ids: dict[str, str],
    already: set[str],
    body_loader: BodyLoader,
) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    declarations: list[str] = []
    fields: list[str] = []
    variables: dict[str, Any] = {}
    build = MutationBuild(label_ids, declarations, variables, body_loader)
    attempted: list[dict[str, Any]] = []
    for index, operation in enumerate(prepared["operations"]):
        if operation["id"] in already:
            continue
        alias = f"o{index}"
        operation["alias"] = alias
        attempted.append(operation)
        declarations.extend((f"$target{index}:ID!", f"$client{index}:String!"))
        variables[f"target{index}"] = operation["target_id"]
        variables[f"client{index}"] = operation["id"]
        fields.append(mutation_field(index, alias, operation, build))
    if not attempted:
        return "", {}, []
    return f"mutation({','.join(declarations)}){{{' '.join(fields)}}}", variables, attempted
