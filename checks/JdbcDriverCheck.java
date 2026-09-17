import java.sql.Driver;

/** Falha no build se o driver nao puder ser carregado pelo runtime da imagem. */
public final class JdbcDriverCheck {
    public static void main(String[] args) throws Exception {
        Driver driver = (Driver) Class.forName("oracle.jdbc.OracleDriver").newInstance();
        if (!driver.acceptsURL("jdbc:oracle:thin:@//localhost:1521/xe")) {
            throw new IllegalStateException("Driver nao reconhece URL Oracle Thin");
        }
        System.out.println("Oracle JDBC carregado: " + driver.getMajorVersion()
                + "." + driver.getMinorVersion() + " em Java " + System.getProperty("java.version"));
    }
}
