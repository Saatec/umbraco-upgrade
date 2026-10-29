using Umbraco.Core;
using Umbraco.Core.Composing;

namespace SampleSite.Web
{
    // Synthetic fixture: registers a custom service.
    public class ServicesComposer : IUserComposer
    {
        public void Compose(Composition composition)
        {
            composition.Register<IGreeting, Greeting>(Lifetime.Request);
        }
    }

    public interface IGreeting { string Text(); }

    public class Greeting : IGreeting { public string Text() => "Hello"; }
}
