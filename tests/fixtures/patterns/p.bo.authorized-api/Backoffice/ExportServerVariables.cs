using Umbraco.Cms.Core.Events;
using Umbraco.Cms.Core.Notifications;

namespace SampleSite.Web.Backoffice;

// Synthetic fixture: adds a value to the backoffice server variables.
public class ExportServerVariables : INotificationHandler<ServerVariablesParsingNotification>
{
    public void Handle(ServerVariablesParsingNotification notification)
    {
        notification.ServerVariables.Add("sampleSiteExport", new { enabled = true });
    }
}
