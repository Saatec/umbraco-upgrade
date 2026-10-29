using System.Net.Mail;

namespace SampleSite.Web.Services;

// Synthetic fixture: sends a contact message by SMTP.
public class ContactMailer
{
    public void Send(string to, string body)
    {
        using var client = new SmtpClient("localhost", 25);
        client.Send("noreply@example.invalid", to, "Contact", body);
    }
}
