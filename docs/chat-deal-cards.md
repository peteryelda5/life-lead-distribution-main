# Deal cards and View deal

Live Chat deal announcements display AP, monthly premium, carrier, product and the announcement's reporting agency. They are labeled submitted; they do not imply carrier approval.

View deal calls the invoker-rights `chat_deal_view` RPC, preserving message SELECT RLS, verified session and onboarding checks. The response is an explicit summary allowlist. A private fixed-search-path helper returns a policy ID only when existing Book of Business scope permits it. The UI prepares that selection and follows the normal Book of Business access/PIN flow. Other viewers receive a summary without client data or commissions. Removed announcements cannot open a policy. In-flight responses are discarded after account/session changes.

The endpoint reads one indexed message and a matching policy, with a five-second statement timeout. It performs no writes and fails closed on missing/inaccessible messages. Existing API ingress controls apply; there is no new custom per-user rate counter.

Validation: rollback SQL exercises authorized links and unauthorized summary-only responses across active sessions, response allowlist, unknown messages, unverified and anonymous denial. DOM tests cover escaping, both click paths, errors, removed deals and account switches. Existing Book of Business detail authorization and PIN checks remain unchanged.

Rollback: revert the frontend commit, then drop public.chat_deal_view(bigint) and private.chat_deal_policy_link(uuid) after old clients have refreshed. No business data migration is involved.
