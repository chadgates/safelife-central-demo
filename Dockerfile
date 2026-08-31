# ---- build: compiles inside the image, so nobody needs the .NET SDK locally ----
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first, as its own layer, so code edits do not re-download packages.
COPY src/SafeLife.Central/SafeLife.Central.csproj ./SafeLife.Central/
RUN dotnet restore ./SafeLife.Central/SafeLife.Central.csproj

# AngularJS is vendored in wwwroot/vendor, so there is no npm step and no network here.
COPY src/SafeLife.Central/ ./SafeLife.Central/
RUN dotnet publish ./SafeLife.Central/SafeLife.Central.csproj \
        -c Release -o /app --no-restore

# ---- runtime: ~110 MB, no SDK, no shell tooling ----
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app .

# 8080 HTTP (Caddy proxies to this), 9770 the device listener.
EXPOSE 8080 9770

# Workstation GC: this container is sized in hundreds of MB, not GB.
ENV DOTNET_gcServer=0

# Provided by the base image (UID 1654). Both ports are >1024, so root is not needed.
USER $APP_UID

ENTRYPOINT ["dotnet", "SafeLife.Central.dll"]
