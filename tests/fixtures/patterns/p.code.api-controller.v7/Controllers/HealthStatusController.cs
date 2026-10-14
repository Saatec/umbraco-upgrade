using System.Web.Http;

namespace SampleSite.Web.Controllers
{
    // Synthetic fixture: plain Web API controller with attribute routing.
    [RoutePrefix("api/status")]
    public class HealthStatusController : System.Web.Http.ApiController
    {
        [HttpGet]
        [Route("ping")]
        public IHttpActionResult Ping()
        {
            return Ok("pong");
        }
    }
}
