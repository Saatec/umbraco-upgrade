using System.Web.Mvc;
using Umbraco.Web.Models;
using Umbraco.Web.Mvc;

namespace SampleSite.Web.Controllers
{
    // Synthetic fixture: route hijacking for the "productPage" content type.
    public class ProductPageController : RenderMvcController
    {
        public override ActionResult Index(RenderModel model)
        {
            var viewModel = new ProductPageViewModel(model.Content)
            {
                Heading = model.Content.Name
            };
            return CurrentTemplate(viewModel);
        }
    }

    public class ProductPageViewModel : RenderModel
    {
        public ProductPageViewModel(Umbraco.Core.Models.IPublishedContent content) : base(content) { }

        public string Heading { get; set; }
    }
}
