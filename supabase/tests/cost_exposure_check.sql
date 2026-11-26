-- Cost exposure review query. This is not a migration.
--
-- Run this before each go-live and review every row by eye. Every result
-- must be either intentional or protected by RLS. The name match is broad
-- on purpose: cost, wholesale, margin and profit-like columns all deserve
-- review whenever authenticated can read them.

select
  c.table_name,
  c.column_name
from information_schema.columns c
join information_schema.tables t
  on t.table_schema = c.table_schema
 and t.table_name = c.table_name
where c.table_schema = 'public'
  and t.table_type = 'BASE TABLE'
  and c.column_name ~* '(cost|wholesale|margin|profit)'
  and has_column_privilege(
    'authenticated',
    format('%I.%I', c.table_schema, c.table_name),
    c.column_name,
    'select'
  )
order by c.table_name, c.column_name;
