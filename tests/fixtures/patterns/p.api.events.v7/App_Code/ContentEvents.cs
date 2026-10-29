using Umbraco.Core;
using Umbraco.Core.Events;
using Umbraco.Core.Models;
using Umbraco.Core.Services;

namespace SampleSite.Web
{
    // Synthetic fixture: subscribes to content saving at startup.
    public class ContentEvents : ApplicationEventHandler
    {
        protected override void ApplicationStarted(UmbracoApplicationBase umbracoApplication, ApplicationContext applicationContext)
        {
            ContentService.Saving += OnSaving;
        }

        private void OnSaving(IContentService sender, SaveEventArgs<IContent> e)
        {
        }
    }
}
