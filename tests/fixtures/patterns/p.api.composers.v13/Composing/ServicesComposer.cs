using Microsoft.Extensions.DependencyInjection;
using Umbraco.Cms.Core.Composing;
using Umbraco.Cms.Core.DependencyInjection;

namespace SampleSite.Web.Composing;

// Synthetic fixture: registers a custom service.
public class ServicesComposer : IComposer
{
    public void Compose(IUmbracoBuilder builder)
    {
        builder.Services.AddScoped<IGreeting, Greeting>();
    }
}

public interface IGreeting { string Text(); }

public class Greeting : IGreeting { public string Text() => "Hello"; }
