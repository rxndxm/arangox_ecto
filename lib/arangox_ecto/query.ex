defmodule ArangoXEcto.Query do
  @moduledoc """
  Converts `Ecto.Query` structs into AQL syntax.

  This module is copied from
  https://github.com/ArangoDB-Community/arangodb_ecto/blob/master/lib/arangodb_ecto/query.ex.
  All credit goes to `mpoeter`, the original author. Please go check out the original of this file.

  This is an updated version for Ecto V3
  """

  alias Ecto.Query
  alias Ecto.Query.{BooleanExpr, JoinExpr, QueryExpr}

  @doc """
  Creates an AQL query to fetch all entries from the data store matching the given query.
  """
  @spec all(%Query{}) :: binary()
  def all(%Query{} = query) do
    sources = create_names(query)

    from = from(query, sources)
    join = join(query, sources)
    where = where(query, sources)
    order_by = order_by(query, sources)
    offset_and_limit = offset_and_limit(query, sources)
    select = select(query, sources)

    IO.iodata_to_binary([from, join, where, order_by, offset_and_limit, select])
  end

  @doc """
  Creates an AQL query to delete all entries from the data store matching the given query.
  """
  @spec delete_all(%Query{}) :: binary()
  def delete_all(query) do
    sources = create_names(query)

    from = from(query, sources)
    join = join(query, sources)
    where = where(query, sources)
    order_by = order_by(query, sources)
    offset_and_limit = offset_and_limit(query, sources)
    remove = remove(query, sources)
    return = returning("OLD", query, sources)

    IO.iodata_to_binary([from, join, where, order_by, offset_and_limit, remove, return])
  end

  @doc """
  Creates an AQL query to update all entries from the data store matching the given query.
  """
  @spec update_all(%Query{}) :: binary()
  def update_all(query) do
    sources = create_names(query)

    from = from(query, sources)
    join = join(query, sources)
    where = where(query, sources)
    order_by = order_by(query, sources)
    offset_and_limit = offset_and_limit(query, sources)
    update = update(query, sources)
    return = returning("NEW", query, sources)

    IO.iodata_to_binary([from, join, where, order_by, offset_and_limit, update, return])
  end

  #
  # Helpers
  #

  defp create_names(%{sources: nil, from: %{source: {source, mod}}} = query) do
    query
    |> Map.put(:sources, {{source, mod, nil}})
    |> create_names()
  end

  defp create_names(%{sources: sources}) do
    create_names(sources, 0, tuple_size(sources)) |> List.to_tuple()
  end

  defp create_names(sources, pos, limit) when pos < limit do
    current =
      case elem(sources, pos) do
        {:fragment, _, _} ->
          raise "Fragments are not supported."

        {coll, schema, _} ->
          name = [String.first(coll) | Integer.to_string(pos)]
          {quote_collection(coll), name, schema}

        %Ecto.SubQuery{} ->
          raise "Subqueries are not supported."
      end

    [current | create_names(sources, pos + 1, limit)]
  end

  defp create_names(_sources, pos, pos) do
    []
  end

  defp from(%Query{from: from} = query, sources) do
    {coll, name} = get_source(query, sources, 0, from)
    ["FOR ", name, " IN " | coll]
  end

  defp join(%Query{joins: []}, _sources), do: []

  defp join(%Query{joins: joins} = query, sources) do
    [
      ?\s
      | intersperse_map(joins, ?\s, fn %JoinExpr{
                                         on: %QueryExpr{expr: expr},
                                         qual: qual,
                                         ix: ix,
                                         source: source
                                       } ->
          {join, name} = get_source(query, sources, ix, source)
          # [join_qual(qual), join, " AS ", name, " FILTER " | expr(expr, sources, query)]
          if qual != :inner, do: raise("Only inner joins are supported.")
          ["FOR ", name, " IN ", join, " FILTER " | expr(expr, sources, query)]
        end)
    ]
  end

  defp where(%Query{wheres: wheres} = query, sources) do
    boolean(" FILTER ", wheres, sources, query)
  end

  defp order_by(%Query{order_bys: []}, _sources), do: []

  defp order_by(%Query{order_bys: order_bys} = query, sources) do
    [
      " SORT "
      | intersperse_map(order_bys, ", ", fn %QueryExpr{expr: expr} ->
          intersperse_map(expr, ", ", &order_by_expr(&1, sources, query))
        end)
    ]
  end

  defp order_by_expr({dir, expr}, sources, query) do
    str = expr(expr, sources, query)

    case dir do
      :asc -> str
      :desc -> [str | " DESC"]
    end
  end

  defp offset_and_limit(%Query{offset: nil, limit: nil}, _sources), do: []

  defp offset_and_limit(%Query{offset: nil, limit: %QueryExpr{expr: expr}} = query, sources) do
    [" LIMIT " | expr(expr, sources, query)]
  end

  defp offset_and_limit(%Query{offset: %QueryExpr{expr: _}, limit: nil} = query, _) do
    error!(query, "offset can only be used in conjunction with limit")
  end

  defp offset_and_limit(
         %Query{offset: %QueryExpr{expr: offset_expr}, limit: %QueryExpr{expr: limit_expr}} =
           query,
         sources
       ) do
    [" LIMIT ", expr(offset_expr, sources, query), ", ", expr(limit_expr, sources, query)]
  end

  defp remove(%Query{from: from} = query, sources) do
    {coll, name} = get_source(query, sources, 0, from)
    [" REMOVE ", name, " IN " | coll]
  end

  defp update(%Query{from: from} = query, sources) do
    {coll, name} = get_source(query, sources, 0, from)
    fields = update_fields(query, sources)
    [" UPDATE ", name, " WITH {", fields, "} IN " | coll]
  end

  defp returning(_, %Query{select: nil}, _sources), do: []

  defp returning(version, query, sources) do
    {source, _, schema} = elem(sources, 0)
    select(query, {{source, version, schema}})
  end

  defp select(%Query{select: nil}, _sources), do: [" RETURN []"]

  defp select(%Query{select: %{fields: fields}, distinct: distinct, from: from} = query, sources),
    do: select_fields(fields, distinct, from, sources, query)

  defp select_fields(fields, distinct, _from, sources, query) do
    values =
      intersperse_map(fields, ", ", fn
        {_key, value} ->
          [expr(value, sources, query)]

        value ->
          [expr(value, sources, query)]
      end)

    [" RETURN ", distinct(distinct, sources, query), "[ ", values | " ]"]
  end

  defp update_fields(%Query{from: from, updates: updates} = query, sources) do
    {_from, name} = get_source(query, sources, 0, from)

    fields =
      for(
        %{expr: expr} <- updates,
        {op, kw} <- expr,
        {key, value} <- kw,
        do: update_op(op, name, quote_name(key), value, sources, query)
      )

    Enum.intersperse(fields, ", ")
  end

  defp update_op(cmd, name, quoted_key, value, sources, query) do
    value = update_op_value(cmd, name, quoted_key, value, sources, query)
    [quoted_key, ": " | value]
  end

  defp update_op_value(:set, _name, _quoted_key, value, sources, query),
    do: expr(value, sources, query)

  defp update_op_value(:inc, name, quoted_key, value, sources, query),
    do: [name, ?., quoted_key, " + " | expr(value, sources, query)]

  defp update_op_value(:push, name, quoted_key, value, sources, query),
    do: ["PUSH(", name, ?., quoted_key, ", ", expr(value, sources, query), ")"]

  defp update_op_value(:pull, name, quoted_key, value, sources, query),
    do: ["REMOVE_VALUE(", name, ?., quoted_key, ", ", expr(value, sources, query), ", 1)"]

  defp update_op_value(cmd, _name, _quoted_key, _value, _sources, query),
    do: error!(query, "Unknown update operation #{inspect(cmd)} for AQL")

  defp distinct(nil, _sources, _query), do: []
  defp distinct(%QueryExpr{expr: true}, _sources, _query), do: "DISTINCT "
  defp distinct(%QueryExpr{expr: false}, _sources, _query), do: []

  defp distinct(%QueryExpr{expr: exprs}, _sources, query) when is_list(exprs) do
    error!(query, "DISTINCT with multiple fields is not supported by AQL")
  end

  defp get_source(query, sources, ix, source) do
    {expr, name, _schema} = elem(sources, ix)
    {expr || paren_expr(source, sources, query), name}
  end

  defp boolean(_name, [], _sources, _query), do: []

  defp boolean(name, [%{expr: expr, op: op} | query_exprs], sources, query) do
    [
      name,
      Enum.reduce(query_exprs, {op, paren_expr(expr, sources, query)}, fn
        %BooleanExpr{expr: expr, op: op}, {op, acc} ->
          {op, [acc, operator_to_boolean(op) | paren_expr(expr, sources, query)]}

        %BooleanExpr{expr: expr, op: op}, {_, acc} ->
          {op, [?(, acc, ?), operator_to_boolean(op) | paren_expr(expr, sources, query)]}
      end)
      |> elem(1)
    ]
  end

  defp operator_to_boolean(:and), do: " && "
  defp operator_to_boolean(:or), do: " || "

  defp paren_expr(expr, sources, query) do
    [?(, expr(expr, sources, query), ?)]
  end

  #
  # Expressions
  #

  binary_ops = [
    ==: " == ",
    !=: " != ",
    <=: " <= ",
    >=: " >= ",
    <: " < ",
    >: " > ",
    and: " && ",
    or: " || ",
    like: " LIKE "
  ]

  @binary_ops Keyword.keys(binary_ops)

  Enum.map(binary_ops, fn {op, str} ->
    defp handle_call(unquote(op), 2), do: {:binary_op, unquote(str)}
  end)

  defp handle_call(fun, _arity), do: {:fun, Atom.to_string(fun)}

  defp expr({:^, [], [idx]}, _sources, _query) do
    [?@ | Integer.to_string(idx + 1)]
  end

  defp expr({{:., _, [{:&, _, [idx]}, field]}, _, []}, sources, _query)
       when is_atom(field) do
    {_, name, _} = elem(sources, idx)
    [name, ?. | quote_name(field)]
  end

  defp expr({:&, _, [idx, fields, _counter]}, sources, query) do
    {source, name, schema} = elem(sources, idx)

    if is_nil(schema) and is_nil(fields) do
      error!(
        query,
        "ArangoDB does not support selecting all fields from #{source} without a schema. " <>
          "Please specify a schema or specify exactly which fields you want to select"
      )
    end

    intersperse_map(fields, ", ", &[name, ?. | quote_name(&1)])
  end

  defp expr({:not, _, [expr]}, sources, query) do
    ["NOT (", expr(expr, sources, query), ?)]
  end

  defp expr({:fragment, _, parts}, sources, query) do
    Enum.map(parts, fn
      {:raw, part} -> part
      {:expr, expr} -> expr(expr, sources, query)
    end)
  end

  defp expr({:is_nil, _, [arg]}, sources, query) do
    [expr(arg, sources, query) | " == NULL"]
  end

  defp expr({:in, _, [_left, []]}, _sources, _query) do
    "FALSE"
  end

  defp expr({:in, _, [left, right]}, sources, query) when is_list(right) do
    args = intersperse_map(right, ?,, &expr(&1, sources, query))
    [expr(left, sources, query), " IN [", args, ?]]
  end

  defp expr({:in, _, [left, {:^, _, [idx, _length]}]}, sources, query) do
    [expr(left, sources, query), " IN @#{idx + 1}"]
  end

  defp expr({:in, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " IN ", expr(right, sources, query)]
  end

  defp expr({fun, _, args}, sources, query) when is_atom(fun) and is_list(args) do
    case handle_call(fun, length(args)) do
      {:binary_op, op} ->
        [left, right] = args
        [op_to_binary(left, sources, query), op | op_to_binary(right, sources, query)]

      {:fun, fun} ->
        [fun, ?(, [], intersperse_map(args, ", ", &expr(&1, sources, query)), ?)]
    end
  end

  defp expr(literal, _sources, _query) when is_binary(literal) do
    [?', escape_string(literal), ?']
  end

  defp expr(list, sources, query) when is_list(list) do
    [?[, intersperse_map(list, ?,, &expr(&1, sources, query)), ?]]
  end

  defp expr(%Decimal{} = decimal, _sources, _query) do
    Decimal.to_string(decimal, :normal)
  end

  defp expr(literal, _sources, _query) when is_integer(literal) do
    Integer.to_string(literal)
  end

  defp expr(literal, _sources, _query) when is_float(literal) do
    Float.to_string(literal)
  end

  defp expr(%Ecto.Query.Tagged{value: value, type: :binary_id}, sources, query) do
    [expr(value, sources, query)]
  end

  defp expr(nil, _sources, _query), do: "NULL"
  defp expr(true, _sources, _query), do: "TRUE"
  defp expr(false, _sources, _query), do: "FALSE"

  defp op_to_binary({op, _, [_, _]} = expr, sources, query) when op in @binary_ops,
    do: paren_expr(expr, sources, query)

  defp op_to_binary(expr, sources, query), do: expr(expr, sources, query)

  defp quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  defp quote_name(name) do
    if String.contains?(name, "`"), do: error!(nil, "bad field name #{inspect(name)}")
    [?`, name, ?`]
  end

  defp quote_collection(name) when is_atom(name), do: quote_collection(Atom.to_string(name))

  defp quote_collection(name) do
    if String.contains?(name, "`"), do: error!(nil, "bad table name #{inspect(name)}")
    [?`, name, ?`]
  end

  defp intersperse_map(list, separator, mapper, acc \\ [])
  defp intersperse_map([], _separator, _mapper, acc), do: acc
  defp intersperse_map([elem], _separator, mapper, acc), do: [acc | mapper.(elem)]

  defp intersperse_map([elem | rest], separator, mapper, acc),
    do: intersperse_map(rest, separator, mapper, [acc, mapper.(elem), separator])

  defp escape_string(value) when is_binary(value) do
    value
    |> :binary.replace("\\", "\\\\", [:global])
    |> :binary.replace("''", "\\'", [:global])
  end

  defp error!(nil, message) do
    raise ArgumentError, message
  end

  defp error!(query, message) do
    raise Ecto.QueryError, query: query, message: message
  end
end
