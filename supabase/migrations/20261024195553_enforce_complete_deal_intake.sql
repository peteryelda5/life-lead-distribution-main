-- Apply only after the unified submission UI has deployed successfully.
-- Existing deals are unchanged. Outdated forms fail with a refresh instruction.
create trigger require_complete_deal_client before insert on public.closed_business
 for each row execute function private.require_complete_deal_client();
