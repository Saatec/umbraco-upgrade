using Umbraco.Cms.Core.Events;
using Umbraco.Cms.Core.Notifications;

namespace SampleSite.Web.Notifications;

// Synthetic fixture: sets a default title before content is saved.
public class DefaultTitleHandler : INotificationHandler<ContentSavingNotification>
{
    public void Handle(ContentSavingNotification notification)
    {
        foreach (var entity in notification.SavedEntities)
        {
            if (string.IsNullOrWhiteSpace(entity.Name))
            {
                entity.Name = "Untitled";
            }
        }
    }
}
