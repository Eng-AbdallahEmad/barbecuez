-- Live Activity push tokens: stores APNs tokens per order so the
-- push-live-activity Edge Function can send update payloads directly.

CREATE TABLE public.live_activity_tokens (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    uuid        NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  activity_id text        NOT NULL,
  push_token  text        NOT NULL,
  platform    text        NOT NULL DEFAULT 'ios',
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id, activity_id)
);

ALTER TABLE public.live_activity_tokens ENABLE ROW LEVEL SECURITY;

-- Only the service role (Edge Functions) may read/write this table.
CREATE POLICY "service_role_only"
  ON public.live_activity_tokens
  FOR ALL
  USING (false);

-- ── Trigger: notify Live Activity when order status changes ─────────────────
-- Requires the pg_net extension (enabled by default on Supabase).
-- Set app.supabase_url and app.service_role_key in the Supabase dashboard
-- under Settings → Database → Configuration → Custom config parameters.

CREATE OR REPLACE FUNCTION public.notify_live_activity_on_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM net.http_post(
      url     := current_setting('app.supabase_url') || '/functions/v1/push-live-activity',
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || current_setting('app.service_role_key')
      ),
      body    := jsonb_build_object(
        'orderId',     NEW.id,
        'status',      NEW.status,
        'statusLabel', CASE NEW.status
          WHEN 'preparing'        THEN 'Preparing your order'
          WHEN 'ready'            THEN 'Ready for pickup'
          WHEN 'out_for_delivery' THEN 'On the way'
          WHEN 'delivered'        THEN 'Delivered!'
          WHEN 'cancelled'        THEN 'Order cancelled'
          ELSE NEW.status
        END,
        'etaMinutes', COALESCE(NEW.estimated_minutes, 20),
        'progress',   CASE NEW.status
          WHEN 'pending'          THEN 0.1
          WHEN 'preparing'        THEN 0.35
          WHEN 'ready'            THEN 0.6
          WHEN 'out_for_delivery' THEN 0.8
          WHEN 'delivered'        THEN 1.0
          ELSE 0.5
        END,
        'dismiss', NEW.status IN ('delivered', 'completed', 'cancelled')
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_live_activity_on_status
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_live_activity_on_status_change();
