# Synthetic fixture: container image for the site.
FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY publish/ .
ENTRYPOINT ["dotnet", "SampleSite.Web.dll"]
