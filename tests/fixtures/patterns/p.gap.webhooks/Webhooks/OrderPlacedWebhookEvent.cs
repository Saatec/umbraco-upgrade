using Umbraco.Cms.Core.Webhooks;

namespace SampleSite.Web.Webhooks;

// Synthetic fixture: a custom webhook event type.
public class OrderPlacedWebhookEvent : IWebhookEvent
{
    public string EventName => "Order placed";
    public string EventType => "Custom";
    public string Alias => "sampleSite.orderPlaced";
}
