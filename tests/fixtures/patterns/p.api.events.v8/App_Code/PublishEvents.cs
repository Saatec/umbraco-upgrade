using Umbraco.Core;
using Umbraco.Core.Composing;
using Umbraco.Core.Events;
using Umbraco.Core.Services;
using Umbraco.Core.Services.Implement;

namespace SampleSite.Web
{
    // Synthetic fixture: subscribes to publishing in a component.
    public class PublishEventsComposer : ComponentComposer<PublishEventsComponent>, IUserComposer
    {
    }

    public class PublishEventsComponent : IComponent
    {
        public void Initialize()
        {
            ContentService.Published += OnPublished;
        }

        public void Terminate()
        {
            ContentService.Published -= OnPublished;
        }

        private void OnPublished(IContentService sender, ContentPublishedEventArgs e)
        {
        }
    }
}
